#!/usr/bin/env bash
# Tests oauth-secret.sh against a fake `aws` on PATH. No AWS access, no network.
# Proves: dry run touches nothing and does not read stdin; --apply creates or updates the right secret with the right
# JSON; the client secret is never in any argument, any output, or any file left behind; failures change nothing.
# Run from anywhere: test/oauth-secret.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
SENTINEL="s3ntinel-client-secret-0123456789abcdef"

# The fake aws: logs argv; describe-secret answers from $FAKE_MODE; create/put copy the secret file's content and mode.
cat > "$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_AWS_DIR/calls.log"
op="$2"
for a in "$@"; do case "$a" in file://*) f="${a#file://}"; cp "$f" "$FAKE_AWS_DIR/stored.json"; stat -c %a "$f" > "$FAKE_AWS_DIR/mode"; echo "$f" > "$FAKE_AWS_DIR/tmpfile" ;; esac; done
case "$op" in
  describe-secret)
    case "$FAKE_MODE" in
      exists) echo "mopm/gamma/github-oauth" ;;
      missing) echo "An error occurred (ResourceNotFoundException) when calling the DescribeSecret operation: Secrets Manager can't find the specified secret." >&2; exit 254 ;;
      denied) echo "An error occurred (AccessDeniedException) when calling the DescribeSecret operation: not authorized" >&2; exit 254 ;;
    esac ;;
  create-secret) echo "mopm/gamma/github-oauth" ;;
  put-secret-value) echo "version-1" ;;
esac
FAKE
chmod +x "$work/bin/aws"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_in() { grep -qF -- "$1" "$2" || { echo "--- $2"; cat "$2"; fail "expected '$1'"; }; }
expect_not_in() { if grep -qF -- "$1" "$2"; then echo "--- $2"; cat "$2"; fail "did not expect '$1'"; fi; }

scenario() { # name, mode
  export FAKE_AWS_DIR="$work/$1" FAKE_MODE="$2"; rm -rf "$FAKE_AWS_DIR"; mkdir -p "$FAKE_AWS_DIR"; : > "$FAKE_AWS_DIR/calls.log"
}
run_script() { # script, stdin text, args...
  local script="$1" input="$2"; shift 2
  set +e
  printf '%s\n' "$input" | PATH="$work/bin:$PATH" "$script" "$@" > "$FAKE_AWS_DIR/out" 2>&1
  echo $? > "$FAKE_AWS_DIR/rc"
  set -e
}
base=(--stage gamma --profile p --client-id Iv1.abcdef0123456789)

# 1. Dry run: prints the commands, calls nothing, never mentions the secret.
scenario dry exists; run_script "$here/oauth-secret.sh" "$SENTINEL" "${base[@]}"
d="$FAKE_AWS_DIR"
[ "$(cat "$d/rc")" = 0 ] || { cat "$d/out"; fail "dry run exit code"; }
expect_in 'DRY-RUN: aws secretsmanager create-secret' "$d/out"
expect_in 'mopm/gamma/github-oauth' "$d/out"
expect_not_in "$SENTINEL" "$d/out"
[ ! -s "$d/calls.log" ] || fail "a dry run called aws"

# 2. --apply, secret missing: created with the JSON from stdin, in a 600 file, nothing left behind.
scenario create missing; run_script "$here/oauth-secret.sh" "$SENTINEL" "${base[@]}" --apply
d="$FAKE_AWS_DIR"
[ "$(cat "$d/rc")" = 0 ] || { cat "$d/out"; fail "create exit code"; }
expect_in 'secretsmanager create-secret --profile p --region us-east-1 --name mopm/gamma/github-oauth' "$d/calls.log"
expect_not_in 'put-secret-value' "$d/calls.log"
[ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["client_id"], d["client_secret"])' "$d/stored.json")" = "Iv1.abcdef0123456789 $SENTINEL" ] || fail "stored JSON is wrong"
[ "$(cat "$d/mode")" = 600 ] || fail "secret file mode is $(cat "$d/mode"), want 600"
[ ! -e "$(cat "$d/tmpfile")" ] || fail "temporary secret file left behind"
expect_not_in "$SENTINEL" "$d/out"
expect_not_in "$SENTINEL" "$d/calls.log"   # argv

# 3. --apply, secret exists: a new version, not a second create.
scenario update exists; run_script "$here/oauth-secret.sh" "$SENTINEL" "${base[@]}" --apply --region us-west-2
d="$FAKE_AWS_DIR"
[ "$(cat "$d/rc")" = 0 ] || { cat "$d/out"; fail "update exit code"; }
expect_in 'secretsmanager put-secret-value --profile p --region us-west-2 --secret-id mopm/gamma/github-oauth' "$d/calls.log"
expect_not_in 'create-secret' "$d/calls.log"
expect_not_in "$SENTINEL" "$d/out"
expect_not_in "$SENTINEL" "$d/calls.log"

# 4. --apply, describe fails for another reason: stop, change nothing.
scenario denied denied; run_script "$here/oauth-secret.sh" "$SENTINEL" "${base[@]}" --apply
d="$FAKE_AWS_DIR"
[ "$(cat "$d/rc")" != 0 ] || fail "must stop when the secret cannot be read"
expect_not_in 'create-secret' "$d/calls.log"
expect_not_in 'put-secret-value' "$d/calls.log"
expect_not_in "$SENTINEL" "$d/out"

# 5. Bad input: nothing is called.
scenario badin missing
run_script "$here/oauth-secret.sh" "" "${base[@]}" --apply
[ "$(cat "$FAKE_AWS_DIR/rc")" = 2 ] || fail "empty secret must exit 2"
run_script "$here/oauth-secret.sh" "has a space" "${base[@]}" --apply
[ "$(cat "$FAKE_AWS_DIR/rc")" = 2 ] || fail "secret with whitespace must exit 2"
run_script "$here/oauth-secret.sh" "$SENTINEL" --stage dev --profile p --client-id Iv1.abcdef0123456789 --apply
[ "$(cat "$FAKE_AWS_DIR/rc")" = 2 ] || fail "bad stage must exit 2"
run_script "$here/oauth-secret.sh" "$SENTINEL" --stage beta --client-id Iv1.abcdef0123456789 --apply
[ "$(cat "$FAKE_AWS_DIR/rc")" = 2 ] || fail "missing profile must exit 2"
run_script "$here/oauth-secret.sh" "$SENTINEL" --stage beta --profile p --client-id 'bad id' --apply
[ "$(cat "$FAKE_AWS_DIR/rc")" = 2 ] || fail "bad client id must exit 2"
run_script "$here/oauth-secret.sh" "$SENTINEL" --stage beta --profile p --client-id Iv1.abcdef0123456789 --apply --force
[ "$(cat "$FAKE_AWS_DIR/rc")" = 2 ] || fail "unknown flag (there is no --force) must exit 2"
[ ! -s "$FAKE_AWS_DIR/calls.log" ] || fail "bad input called aws"

# 6. Can-fail proof: a copy that puts the secret in the command line is caught by the argv check above.
mutant="$work/mutant.sh"
sed -e '/^unset client_secret/d' -e 's#--secret-string "file://${tmp}"#--secret-string "$client_secret"#' "$here/oauth-secret.sh" > "$mutant"
chmod +x "$mutant"
grep -q -- '--secret-string "$client_secret"' "$mutant" || fail "mutant was not built"
scenario mutant missing; run_script "$mutant" "$SENTINEL" "${base[@]}" --apply
grep -qF -- "$SENTINEL" "$FAKE_AWS_DIR/calls.log" || fail "the argv check cannot see a secret passed as an argument"

echo "oauth-secret.sh: all scenarios pass"
