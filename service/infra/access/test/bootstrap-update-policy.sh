#!/usr/bin/env bash
# Tests bootstrap.sh --update-policy / --policy-only against a fake `aws` on PATH. No AWS access, no network.
# Run from anywhere: test/bootstrap-update-policy.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
acct="$(printf '5%.0s' $(seq 12))"

# The fake aws: logs every call; answers the few IAM reads bootstrap.sh makes from files in $FAKE_AWS_DIR.
cat > "$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_AWS_DIR/calls.log"
case "$1 $2" in
  "iam get-policy")
    if [ -e "$FAKE_AWS_DIR/missing" ]; then echo "An error occurred (NoSuchEntity) when calling the GetPolicy operation" >&2; exit 254; fi
    echo v5 ;;
  "iam get-policy-version") cat "$FAKE_AWS_DIR/current.json" ;;
  "iam list-policy-versions")
    case "$*" in *'length('*) cat "$FAKE_AWS_DIR/count" ;; *) echo v2 ;; esac ;;
esac
FAKE
chmod +x "$work/bin/aws"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_in() { grep -qF -- "$1" "$2" || { echo "--- $2"; cat "$2"; fail "expected '$1'"; }; }
expect_not_in() { if grep -qF -- "$1" "$2"; then echo "--- $2"; cat "$2"; fail "did not expect '$1'"; fi; }
line_of() { grep -nF -- "$1" "$2" | head -1 | cut -d: -f1; }

scenario() { # name, count, current-doc-json|rendered|missing
  export FAKE_AWS_DIR="$work/$1"; mkdir -p "$FAKE_AWS_DIR"; : > "$FAKE_AWS_DIR/calls.log"
  echo "$2" > "$FAKE_AWS_DIR/count"
  rm -f "$FAKE_AWS_DIR/missing"
  case "$3" in
    missing) touch "$FAKE_AWS_DIR/missing" ;;
    rendered) sed -e 's/{{STAGE}}/gamma/g' -e "s/{{ACCOUNT}}/${acct}/g" -e 's/{{ZONE}}/gamma.mopm.dev/g' "$here/cfn-exec-policy.template.json" > "$FAKE_AWS_DIR/current.json" ;;
    *) echo "$3" > "$FAKE_AWS_DIR/current.json" ;;
  esac
}
run_script() { # scenario dir name, args...; stdout+stderr to $FAKE_AWS_DIR/out, exit code to $FAKE_AWS_DIR/rc
  local out="$FAKE_AWS_DIR/out"; shift
  set +e
  PATH="$work/bin:$PATH" "$here/bootstrap.sh" --stage gamma --account "$acct" --region us-east-1 --profile p "$@" > "$out" 2>&1
  echo $? > "$FAKE_AWS_DIR/rc"
  set -e
}
OLD='{"Version":"2012-10-17","Statement":[{"Sid":"Old","Effect":"Allow","Action":"s3:*","Resource":"*"}]}'

# 1. dry run, differs, 5 versions: diff shown, delete + create-version printed, nothing mutated.
scenario dry 5 "$OLD"; run_script dry --update-policy --policy-only
d="$FAKE_AWS_DIR"
[ "$(cat "$d/rc")" = 0 ] || { cat "$d/out"; fail "dry run exit code"; }
expect_in '--- current mopm-gamma-cfn-exec (v5)' "$d/out"
expect_in '+++ new (gamma)' "$d/out"
expect_in '+      "Sid": "Route53RecordsInStageZone"' "$d/out"
expect_in '-      "Sid": "Old"' "$d/out"
expect_in 'gamma.mopm.dev' "$d/out"
expect_in 'DRY-RUN: aws iam delete-policy-version' "$d/out"
expect_in 'DRY-RUN: aws iam create-policy-version' "$d/out"
expect_in '--set-as-default' "$d/out"
expect_not_in '+ aws' "$d/out"
expect_not_in 'create-policy-version' "$d/calls.log"
expect_not_in 'delete-policy-version' "$d/calls.log"
expect_not_in 'cdk bootstrap' "$d/out"

# 2. --apply, differs, 5 versions: oldest non-default deleted first, then the new default version; no new policy created.
scenario apply5 5 "$OLD"; run_script apply5 --update-policy --policy-only --apply
d="$FAKE_AWS_DIR"
[ "$(cat "$d/rc")" = 0 ] || { cat "$d/out"; fail "apply exit code"; }
expect_in 'iam delete-policy-version --profile p --policy-arn arn:aws:iam::'"${acct}"':policy/mopm-gamma-cfn-exec --version-id v2' "$d/calls.log"
expect_in '--set-as-default' "$d/calls.log"
[ "$(line_of delete-policy-version "$d/calls.log")" -lt "$(line_of create-policy-version "$d/calls.log")" ] || fail "delete must precede create"
expect_not_in 'iam create-policy ' "$d/calls.log"

# 3. fewer than 5 versions: nothing deleted.
scenario apply3 3 "$OLD"; run_script apply3 --update-policy --policy-only --apply
d="$FAKE_AWS_DIR"
[ "$(cat "$d/rc")" = 0 ] || { cat "$d/out"; fail "apply3 exit code"; }
expect_in 'iam create-policy-version' "$d/calls.log"
expect_not_in 'delete-policy-version' "$d/calls.log"

# 4. differs but no --update-policy: stops, changes nothing, says how to proceed.
scenario noflag 5 "$OLD"; run_script noflag --policy-only --apply
d="$FAKE_AWS_DIR"
[ "$(cat "$d/rc")" != 0 ] || fail "must stop when the policy differs and --update-policy is absent"
expect_in 'DIFFERENT document' "$d/out"
expect_in '--update-policy' "$d/out"
expect_not_in 'create-policy' "$d/calls.log"
expect_not_in 'delete-policy-version' "$d/calls.log"

# 5. identical: skipped, nothing mutated, even with --update-policy.
scenario same 5 rendered; run_script same --update-policy --policy-only --apply
d="$FAKE_AWS_DIR"
[ "$(cat "$d/rc")" = 0 ] || { cat "$d/out"; fail "identical exit code"; }
expect_in 'identical document' "$d/out"
expect_not_in 'create-policy' "$d/calls.log"
expect_not_in 'delete-policy-version' "$d/calls.log"

# 6. missing policy: it is created (no version call).
scenario missing 0 missing; run_script missing --update-policy --policy-only --apply
d="$FAKE_AWS_DIR"
[ "$(cat "$d/rc")" = 0 ] || { cat "$d/out"; fail "missing exit code"; }
expect_in 'iam create-policy --profile p --policy-name mopm-gamma-cfn-exec' "$d/calls.log"
expect_not_in 'create-policy-version' "$d/calls.log"

# 7. --policy-only never reaches cdk.
expect_not_in 'cdk bootstrap' "$d/out"
echo "bootstrap.sh --update-policy: all scenarios pass"
