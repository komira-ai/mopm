#!/usr/bin/env bash
# Deploys the Route 53 hosted zone of one stage (or, with --delegate, the prod delegation records).
# Run by a human admin with their OWN credentials. Dry-run by default: prints the commands.
# --apply is required to act. Never forces. All configuration is flags (no environment variables are read).
set -euo pipefail

usage() {
  cat <<USAGE
usage:
  dns.sh --stage beta|gamma|prod --account <12 digits> --profile <aws profile> [--apply]
      Deploys mopm-dns-<stage>-zone and prints the zone's four name servers.
  dns.sh --stage prod --delegate --beta-ns <4 hosts, comma separated> --gamma-ns <4 hosts, comma separated> \\
         --account <prod account, 12 digits> --profile <prod profile> [--apply]
      Deploys mopm-dns-prod-delegation: NS records for beta.mopm.dev and gamma.mopm.dev in the mopm.dev zone.
  Without --apply nothing is executed; the commands are printed.
USAGE
}

stage=""; account=""; profile=""; apply=0; delegate=0; beta_ns=""; gamma_ns=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) stage="${2:-}"; shift 2 ;;
    --account) account="${2:-}"; shift 2 ;;
    --profile) profile="${2:-}"; shift 2 ;;
    --beta-ns) beta_ns="${2:-}"; shift 2 ;;
    --gamma-ns) gamma_ns="${2:-}"; shift 2 ;;
    --delegate) delegate=1; shift ;;
    --apply) apply=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

region="us-east-1"
case "$stage" in beta|gamma|prod) ;; *) echo "--stage must be beta, gamma or prod" >&2; exit 2 ;; esac
[[ "$account" =~ ^[0-9]{12}$ ]] || { echo "--account must be 12 digits" >&2; exit 2; }
[ -n "$profile" ] || { echo "--profile is required" >&2; exit 2; }

ns_re='^ns-[0-9]{1,4}\.awsdns-[0-9]{2}\.(org|com|net|co\.uk)$'
check_ns() { # label, csv
  local label="$1" csv="$2" n=0 h
  IFS=',' read -r -a hosts <<< "$csv"
  for h in "${hosts[@]:-}"; do
    [[ "$h" =~ $ns_re ]] || { echo "$label must be 4 comma separated Route 53 name servers (no trailing dots); got '$h'" >&2; exit 2; }
    n=$((n + 1))
  done
  [ "$n" -eq 4 ] || { echo "$label must list exactly 4 name servers; got $n" >&2; exit 2; }
}

if [ "$delegate" -eq 1 ]; then
  [ "$stage" = prod ] || { echo "--delegate runs in the prod account only (--stage prod)" >&2; exit 2; }
  check_ns --beta-ns "$beta_ns"
  check_ns --gamma-ns "$gamma_ns"
  stack="mopm-dns-prod-delegation"
else
  [ -z "$beta_ns" ] && [ -z "$gamma_ns" ] || { echo "--beta-ns/--gamma-ns only apply with --delegate" >&2; exit 2; }
  stack="mopm-dns-${stage}-zone"
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

run() {
  if [ "$apply" -eq 1 ]; then
    echo "+ $*"
    "$@"
  else
    printf 'DRY-RUN:'; printf ' %q' "$@"; printf '\n'
  fi
}

[ "$apply" -eq 1 ] || echo "# dry run: nothing is executed. Re-run with --apply to act."

run npm ci --ignore-scripts --no-audit --no-fund

# No cdk bootstrap is needed: these stacks use the legacy synthesizer and deploy with your own credentials.
deploy=(npx cdk deploy "$stack" --profile "$profile" --require-approval broadening
        -c "stage=${stage}" -c "account=${account}")
if [ "$delegate" -eq 1 ]; then
  deploy+=(-c delegate=true -c "betaNameServers=${beta_ns}" -c "gammaNameServers=${gamma_ns}")
fi
run "${deploy[@]}"

if [ "$delegate" -eq 0 ]; then
  query="Stacks[0].Outputs[?OutputKey=='NameServers'].OutputValue"
  if [ "$apply" -eq 1 ]; then
    ns="$(aws cloudformation describe-stacks --profile "$profile" --region "$region" --stack-name "$stack" \
          --query "$query" --output text)"
    echo "# Name servers of the ${stage} zone (four, comma separated):"
    echo "$ns"
    echo "# Enter these (one per line, no trailing dots) where the next README step says."
  else
    run aws cloudformation describe-stacks --profile "$profile" --region "$region" --stack-name "$stack" \
      --query "$query" --output text
  fi
else
  echo "# Verify: dig +short NS beta.mopm.dev; dig +short NS gamma.mopm.dev (see README.md)."
fi
