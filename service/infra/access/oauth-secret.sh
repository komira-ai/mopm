#!/usr/bin/env bash
# Stores one stage's GitHub OAuth app credentials in AWS Secrets Manager, as the secret
# mopm/<stage>/github-oauth (JSON {"client_id": ..., "client_secret": ...}). Run by a human admin with their OWN
# credentials, once per stage, after creating that stage's GitHub OAuth app (BOOTSTRAP.md, "GitHub OAuth app").
# Dry-run by default: prints what it would do and touches nothing. --apply is required to act. Never forces.
# All configuration is flags. The client SECRET is read from standard input, never from a flag or an environment
# variable (argv is world-readable), and is never printed: not in the dry run, not with --apply, not in errors.
#
#   service/infra/access/oauth-secret.sh --stage beta --profile <aws profile> --client-id <id>        # dry run
#   printf '%s' "$CLIENT_SECRET" | service/infra/access/oauth-secret.sh --stage beta --profile <aws profile> --client-id <id> --apply
#   service/infra/access/oauth-secret.sh --stage beta --profile <aws profile> --client-id <id> --apply   # prompts, input hidden
set -euo pipefail

usage() {
  cat <<USAGE
usage: oauth-secret.sh --stage beta|gamma|prod --profile <aws profile> --client-id <GitHub OAuth app client id> [--region <region>] [--apply]
  Creates the secret mopm/<stage>/github-oauth, or stores a new version when it already exists.
  The client secret is read from stdin (hidden prompt when stdin is a terminal). The client id is not secret.
  --region defaults to us-east-1, the region every mopm stack is in.
  Without --apply nothing is read from stdin and no AWS call is made: the commands are printed.
USAGE
}

stage=""; profile=""; client_id=""; region="us-east-1"; apply=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) stage="${2:-}"; shift 2 ;;
    --profile) profile="${2:-}"; shift 2 ;;
    --client-id) client_id="${2:-}"; shift 2 ;;
    --region) region="${2:-}"; shift 2 ;;
    --apply) apply=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$stage" in beta|gamma|prod) ;; *) echo "--stage must be beta, gamma or prod" >&2; exit 2 ;; esac
[ -n "$profile" ] || { echo "--profile is required" >&2; exit 2; }
[ -n "$region" ] || { echo "--region must not be empty" >&2; exit 2; }
# The same shape the API accepts (src/http/oauth-secret.ts): GitHub client ids look like Iv1.<hex> or Ov23<alphanumerics>.
[[ "$client_id" =~ ^[A-Za-z0-9._-]{4,100}$ ]] || { echo "--client-id must be 4 to 100 characters of letters, digits, . _ -" >&2; exit 2; }

name="mopm/${stage}/github-oauth"
description="GitHub OAuth app of the mopm ${stage} registry (client id and client secret)"

run() {
  if [ "$apply" -eq 1 ]; then
    echo "+ $*"
    "$@"
  else
    printf 'DRY-RUN:'; printf ' %q' "$@"; printf '\n'
  fi
}

if [ "$apply" -ne 1 ]; then
  echo "# dry run: nothing is read, nothing is called. Re-run with --apply to act."
  echo "# the secret string is JSON {\"client_id\": \"${client_id}\", \"client_secret\": \"<read from stdin>\"}, passed to the CLI as a file (mode 600), never as an argument."
  run aws secretsmanager describe-secret --profile "$profile" --region "$region" --secret-id "$name"
  run aws secretsmanager create-secret --profile "$profile" --region "$region" --name "$name" --description "$description" --secret-string "file://<temporary file>"
  echo "# if the secret already exists, put-secret-value is used instead of create-secret:"
  run aws secretsmanager put-secret-value --profile "$profile" --region "$region" --secret-id "$name" --secret-string "file://<temporary file>"
  exit 0
fi

# Read the client secret: hidden prompt on a terminal, otherwise the first line of stdin.
if [ -t 0 ]; then
  printf 'GitHub OAuth app client secret for %s (input hidden): ' "$stage" >&2
  IFS= read -rs client_secret
  printf '\n' >&2
else
  IFS= read -r client_secret || true
fi
[ -n "$client_secret" ] || { echo "the client secret is empty (give it on stdin)" >&2; exit 2; }
case "$client_secret" in *[[:space:]]*|*'"'*|*'\'*) echo "the client secret has whitespace or quote characters; GitHub client secrets do not" >&2; exit 2 ;; esac

umask 077
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
# printf is a shell builtin, so the secret is never in any process's argument list; python reads it from stdin.
printf '%s' "$client_secret" | python3 -c 'import json,sys; print(json.dumps({"client_id": sys.argv[1], "client_secret": sys.stdin.read()}))' "$client_id" > "$tmp"
unset client_secret

# Existing? A missing secret is the normal first run; any other failure stops here.
if out="$(aws secretsmanager describe-secret --profile "$profile" --region "$region" --secret-id "$name" --query Name --output text 2>&1)"; then
  echo "secret ${name} exists: storing a new version"
  run aws secretsmanager put-secret-value --profile "$profile" --region "$region" --secret-id "$name" --secret-string "file://${tmp}" --output text --query VersionId
elif [[ "$out" == *ResourceNotFoundException* ]]; then
  echo "secret ${name} does not exist: creating it"
  run aws secretsmanager create-secret --profile "$profile" --region "$region" --name "$name" --description "$description" --secret-string "file://${tmp}" --output text --query Name
else
  echo "cannot read ${name}: ${out}" >&2
  exit 1
fi
echo "done. The API reads the client id from this secret at runtime (cached for five minutes); no redeploy is needed."
