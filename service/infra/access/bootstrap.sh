#!/usr/bin/env bash
# One-time per-stage-account bootstrap, run by a human admin with their OWN credentials.
# Dry-run by default: prints the commands. --apply is required to act. Never forces.
# All configuration is flags (no environment variables are read).
set -euo pipefail

usage() {
  cat <<USAGE
usage: bootstrap.sh --stage beta|gamma|prod --account <12 digits> --region <region> --profile <aws profile> [--repo owner/name] [--apply]
  Runs, in order: create the scoped CloudFormation execution policy, cdk bootstrap, deploy the access stack.
  Without --apply nothing is executed; the commands are printed.
USAGE
}

stage=""; account=""; region=""; profile=""; repo="komira-ai/mopm"; apply=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) stage="${2:-}"; shift 2 ;;
    --account) account="${2:-}"; shift 2 ;;
    --region) region="${2:-}"; shift 2 ;;
    --profile) profile="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --apply) apply=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$stage" in beta|gamma|prod) ;; *) echo "--stage must be beta, gamma or prod" >&2; exit 2 ;; esac
[[ "$account" =~ ^[0-9]{12}$ ]] || { echo "--account must be 12 digits" >&2; exit 2; }
[ -n "$region" ] || { echo "--region is required" >&2; exit 2; }
[ -n "$profile" ] || { echo "--profile is required" >&2; exit 2; }
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "--repo must be owner/name" >&2; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
policy_name="mopm-${stage}-cfn-exec"
policy_arn="arn:aws:iam::${account}:policy/${policy_name}"
policy_file="${here}/cfn-exec-policy.template.json"

run() {
  if [ "$apply" -eq 1 ]; then
    echo "+ $*"
    "$@"
  else
    printf 'DRY-RUN:'; printf ' %q' "$@"; printf '\n'
  fi
}

[ "$apply" -eq 1 ] || echo "# dry run: nothing is executed. Re-run with --apply to act."

# 1. Scoped execution policy: the template with the stage and account filled in.
rendered="$(sed -e "s/{{STAGE}}/${stage}/g" -e "s/{{ACCOUNT}}/${account}/g" "$policy_file")"
if [ "$apply" -eq 1 ]; then
  doc="$(mktemp)"; trap 'rm -f "$doc"' EXIT
  printf '%s\n' "$rendered" > "$doc"
  run aws iam create-policy --profile "$profile" --policy-name "$policy_name" --policy-document "file://${doc}"
else
  echo "# rendered policy document for ${policy_name}:"; printf '%s\n' "$rendered"
  run aws iam create-policy --profile "$profile" --policy-name "$policy_name" --policy-document "file://<rendered above>"
fi

# 2. CDK bootstrap with the scoped policy (never AdministratorAccess).
run npm install --no-audit --no-fund
run npx cdk bootstrap "aws://${account}/${region}" \
  --profile "$profile" --cloudformation-execution-policies "$policy_arn"

# 3. The access stack (GitHub OIDC provider + deploy and e2e roles).
run npx cdk deploy "mopm-${stage}-access" \
  --profile "$profile" --require-approval broadening \
  -c "stage=${stage}" -c "account=${account}" -c "region=${region}" -c "deployRepo=${repo}"

cat <<NEXT
# Remaining manual steps (see BOOTSTRAP.md): set the repo OIDC subject template once,
# create the ${stage} GitHub environment, and store the role ARNs as environment variables.
NEXT
