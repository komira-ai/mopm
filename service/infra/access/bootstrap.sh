#!/usr/bin/env bash
# One-time per-stage-account bootstrap, run by a human admin with their OWN credentials.
# Dry-run by default: prints the commands. --apply is required to act. Never forces.
# All configuration is flags (no environment variables are read).
set -euo pipefail

usage() {
  cat <<USAGE
usage: bootstrap.sh --stage beta|gamma|prod --account <12 digits> --region <region> --profile <aws profile> [--apply] [--approve-iam]
  Runs, in order: create the scoped CloudFormation execution policy (skipped if an identical one exists;
  stops if a different one exists), cdk bootstrap, cdk diff, deploy the access stack.
  Without --apply nothing is executed; the commands are printed.
  --approve-iam passes --require-approval never to cdk deploy, for non-interactive shells. Use it only
  after a human reviewed the printed cdk diff (IAM changes are otherwise confirmed interactively).
USAGE
}

stage=""; account=""; region=""; profile=""; apply=0; approve_iam=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) stage="${2:-}"; shift 2 ;;
    --account) account="${2:-}"; shift 2 ;;
    --region) region="${2:-}"; shift 2 ;;
    --profile) profile="${2:-}"; shift 2 ;;
    --apply) apply=1; shift ;;
    --approve-iam) approve_iam=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$stage" in beta|gamma|prod) ;; *) echo "--stage must be beta, gamma or prod" >&2; exit 2 ;; esac
[[ "$account" =~ ^[0-9]{12}$ ]] || { echo "--account must be 12 digits" >&2; exit 2; }
[ -n "$region" ] || { echo "--region is required" >&2; exit 2; }
[ -n "$profile" ] || { echo "--profile is required" >&2; exit 2; }

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
# Resumable: an existing policy with an identical document is kept; a different one stops the script.
rendered="$(sed -e "s/{{STAGE}}/${stage}/g" -e "s/{{ACCOUNT}}/${account}/g" "$policy_file")"
norm() { python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))'; }
if [ "$apply" -eq 1 ]; then
  doc="$(mktemp)"; trap 'rm -f "$doc"' EXIT
  printf '%s\n' "$rendered" > "$doc"
  if aws iam get-policy --profile "$profile" --policy-arn "$policy_arn" >/dev/null 2>&1; then
    version="$(aws iam get-policy --profile "$profile" --policy-arn "$policy_arn" --query Policy.DefaultVersionId --output text)"
    existing="$(aws iam get-policy-version --profile "$profile" --policy-arn "$policy_arn" --version-id "$version" \
      --query PolicyVersion.Document --output json | norm)"
    wanted="$(norm < "$doc")"
    if [ "$existing" = "$wanted" ]; then
      echo "policy ${policy_name} already exists with an identical document: skipping creation"
    else
      echo "policy ${policy_arn} exists with a DIFFERENT document than cfn-exec-policy.template.json." >&2
      echo "Stopping: this script never forces or creates a new policy version. Review the difference and resolve it by hand." >&2
      exit 1
    fi
  else
    run aws iam create-policy --profile "$profile" --policy-name "$policy_name" --policy-document "file://${doc}"
  fi
else
  echo "# rendered policy document for ${policy_name}:"; printf '%s\n' "$rendered"
  echo "# with --apply: if ${policy_name} exists with an identical document it is skipped; if it differs the script stops."
  run aws iam create-policy --profile "$profile" --policy-name "$policy_name" --policy-document "file://<rendered above>"
fi

# CDK loads the app (bin/access.ts) for every command, including bootstrap, so the context is required throughout.
ctx=(-c "stage=${stage}" -c "account=${account}" -c "region=${region}")

# 2. CDK bootstrap with the scoped policy (never AdministratorAccess).
run npm install --no-audit --no-fund
run npx cdk bootstrap "aws://${account}/${region}" \
  --profile "$profile" --cloudformation-execution-policies "$policy_arn" "${ctx[@]}"

# 3. Always show the diff first. The access stack (GitHub OIDC provider + deploy and e2e roles) deploys with the
# admin's own credentials (CliCredentialsStackSynthesizer), NOT via the scoped execution role, which denies these resources.
run npx cdk diff "mopm-${stage}-access" --profile "$profile" "${ctx[@]}"
approval=broadening
[ "$approve_iam" -eq 1 ] && approval=never
run npx cdk deploy "mopm-${stage}-access" \
  --profile "$profile" --require-approval "$approval" "${ctx[@]}"

cat <<NEXT
# Remaining manual steps (see BOOTSTRAP.md): set the repo OIDC subject template once,
# create the ${stage} GitHub environment, and store AWS_ACCOUNT_ID and AWS_REGION as environment secrets (no ARNs are stored).
NEXT
