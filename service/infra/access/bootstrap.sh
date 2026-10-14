#!/usr/bin/env bash
# One-time per-stage-account bootstrap, run by a human admin with their OWN credentials.
# Dry-run by default: prints the commands. --apply is required to act. Never forces.
# All configuration is flags (no environment variables are read).
set -euo pipefail

usage() {
  cat <<USAGE
usage: bootstrap.sh --stage beta|gamma|prod --account <12 digits> --region <region> --profile <aws profile> [--apply] [--approve-iam] [--update-policy] [--policy-only]
  Runs, in order: create the scoped CloudFormation execution policy (skipped if an identical one exists;
  stops if a different one exists), cdk bootstrap, cdk diff, deploy the access stack.
  Without --apply nothing is executed; the commands are printed.
  --update-policy: if the policy exists with a different document, print the diff (current default version vs
  cfn-exec-policy.template.json) and create the new document as the new default version, first deleting the oldest
  non-default version when IAM's limit of 5 is reached. In a dry run this makes read-only IAM calls (get-policy,
  get-policy-version) to show the diff; if they fail, only the commands are printed.
  --policy-only stops after the policy step (no cdk bootstrap, diff or deploy): the way to roll a policy change out
  to a stage that is already bootstrapped.
  --approve-iam passes --require-approval never to cdk deploy, for non-interactive shells. Use it only
  after a human reviewed the printed cdk diff (IAM changes are otherwise confirmed interactively).
USAGE
}

stage=""; account=""; region=""; profile=""; apply=0; approve_iam=0; update_policy=0; policy_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) stage="${2:-}"; shift 2 ;;
    --account) account="${2:-}"; shift 2 ;;
    --region) region="${2:-}"; shift 2 ;;
    --profile) profile="${2:-}"; shift 2 ;;
    --apply) apply=1; shift ;;
    --approve-iam) approve_iam=1; shift ;;
    --update-policy) update_policy=1; shift ;;
    --policy-only) policy_only=1; shift ;;
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

# 1. Scoped execution policy: the template with the stage, account and zone filled in.
# Resumable: an existing policy with an identical document is kept. A different one stops the script, unless
# --update-policy is given: then the differences are printed and the new document becomes a new default version.
case "$stage" in prod) zone="mopm.dev" ;; *) zone="${stage}.mopm.dev" ;; esac
rendered="$(sed -e "s/{{STAGE}}/${stage}/g" -e "s/{{ACCOUNT}}/${account}/g" -e "s/{{ZONE}}/${zone}/g" "$policy_file")"
case "$rendered" in *'{{'*) echo "cfn-exec-policy.template.json has a placeholder this script does not fill" >&2; exit 1 ;; esac
norm() { python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))'; }
pretty() { python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True, indent=2))'; }
doc="$(mktemp)"; trap 'rm -f "$doc"' EXIT
printf '%s\n' "$rendered" > "$doc"

# Reads: always with --apply; in a dry run only with --update-policy (read-only calls, so the diff can be shown first).
state=unknown; version=""
if [ "$apply" -eq 1 ] || [ "$update_policy" -eq 1 ]; then
  if out="$(aws iam get-policy --profile "$profile" --policy-arn "$policy_arn" --query Policy.DefaultVersionId --output text 2>&1)"; then
    state=exists; version="$out"
  elif [[ "$out" == *NoSuchEntity* ]]; then
    state=missing
  elif [ "$apply" -eq 1 ]; then
    echo "cannot read ${policy_arn}: ${out}" >&2; exit 1
  else
    echo "# could not read ${policy_arn} (${out}); showing the commands only"
  fi
fi

update_version() {
  # IAM keeps at most 5 versions of a managed policy: free a slot first by deleting the oldest non-default one.
  count="$(aws iam list-policy-versions --profile "$profile" --policy-arn "$policy_arn" --query 'length(Versions)' --output text)"
  if [ "$count" -ge 5 ]; then
    oldest="$(aws iam list-policy-versions --profile "$profile" --policy-arn "$policy_arn" \
      --query 'sort_by(Versions[?IsDefaultVersion==`false`], &CreateDate)[0].VersionId' --output text)"
    run aws iam delete-policy-version --profile "$profile" --policy-arn "$policy_arn" --version-id "$oldest"
  fi
  run aws iam create-policy-version --profile "$profile" --policy-arn "$policy_arn" --policy-document "file://${doc}" --set-as-default
}

case "$state" in
  exists)
    existing="$(aws iam get-policy-version --profile "$profile" --policy-arn "$policy_arn" --version-id "$version" \
      --query PolicyVersion.Document --output json)"
    if [ "$(printf '%s' "$existing" | norm)" = "$(norm < "$doc")" ]; then
      echo "policy ${policy_name} already exists with an identical document: skipping"
    elif [ "$update_policy" -eq 1 ]; then
      echo "# policy ${policy_name} differs from cfn-exec-policy.template.json (- current default ${version}, + new):"
      diff -u --label "current ${policy_name} (${version})" --label "new (${stage})" \
        <(printf '%s' "$existing" | pretty) <(pretty < "$doc") || true
      update_version
    else
      echo "policy ${policy_arn} exists with a DIFFERENT document than cfn-exec-policy.template.json." >&2
      echo "Stopping: nothing is changed without --update-policy. Re-run with --update-policy to see the diff and roll the new document out as a new policy version." >&2
      exit 1
    fi
    ;;
  missing)
    [ "$apply" -eq 1 ] || { echo "# rendered policy document for ${policy_name}:"; printf '%s\n' "$rendered"; }
    run aws iam create-policy --profile "$profile" --policy-name "$policy_name" --policy-document "file://${doc}"
    ;;
  *)
    echo "# rendered policy document for ${policy_name}:"; printf '%s\n' "$rendered"
    echo "# with --apply: an existing identical policy is skipped; a different one stops the script unless --update-policy is given."
    if [ "$update_policy" -eq 1 ]; then
      run aws iam create-policy-version --profile "$profile" --policy-arn "$policy_arn" --policy-document "file://<rendered above>" --set-as-default
    else
      run aws iam create-policy --profile "$profile" --policy-name "$policy_name" --policy-document "file://<rendered above>"
    fi
    ;;
esac

if [ "$policy_only" -eq 1 ]; then
  echo "# --policy-only: bootstrap, diff and deploy skipped"
  exit 0
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
