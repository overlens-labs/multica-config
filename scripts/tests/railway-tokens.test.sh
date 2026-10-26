#!/usr/bin/env bash
# Offline test of scripts/railway-tokens.sh: tofu, infisical, curl and jq are
# replaced by shims that log every argv. Fails if any (fictitious) token shows
# up in a process argument, or if the token doesn't reach Infisical.
# Run: scripts/tests/railway-tokens.test.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/railway-tokens.sh"
REAL_JQ="$(command -v jq)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
export ARGV_LOG="$WORK/argv.log" BODY_DIR="$WORK/bodies" REAL_JQ
mkdir -p "$BODY_DIR"; : > "$ARGV_LOG"

PROJECT_TOKEN="fake-project-token-7f3a9c"
export RAILWAY_API_TOKEN="fake-admin-railway-1b2c"
INFISICAL_ADMIN_TOKEN="fake-infisical-session-9d8e"

log_argv() { printf '%s\0' "$@" | tr '\0' ' ' >> "$ARGV_LOG"; echo >> "$ARGV_LOG"; }
export -f log_argv

cat > "$BIN/tofu" <<'SH'
#!/usr/bin/env bash
log_argv tofu "$@"
case "${*: -1}" in
  infisical_host) echo '"https://secrets.example.com"' ;;
  railway_tokens) cat <<JSON
[{"agent":"pe-backend","key":"BILLING_API","project_id":"p1","environment_id":"e1","infisical_project_id":"creds","secret_path":"/pe-backend"},
 {"agent":"pe-backend","key":"CRM_API","project_id":"p2","environment_id":"e2","infisical_project_id":"creds","secret_path":"/pe-backend"}]
JSON
  ;;
esac
SH

cat > "$BIN/infisical" <<SH
#!/usr/bin/env bash
log_argv infisical "\$@"
echo "$INFISICAL_ADMIN_TOKEN"
SH

cat > "$BIN/jq" <<'SH'
#!/usr/bin/env bash
log_argv jq "$@"
exec "$REAL_JQ" "$@"
SH

# curl: Railway returns a project token; Infisical GET says "missing" (404),
# POST stores the body. Header files (-H @file) must carry the bearer tokens.
cat > "$BIN/curl" <<SH
#!/usr/bin/env bash
log_argv curl "\$@"
url="" method=GET headers=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -X) method="\$2"; shift 2 ;;
    -H) [[ "\$2" == @* ]] && headers+="\$(cat "\${2#@}")"; shift 2 ;;
    -o|-w|--data-binary) shift 2 ;;
    http*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
case "\$url" in
  *backboard.railway.com*)
    grep -q "Bearer \$RAILWAY_API_TOKEN" <<<"\$headers" || { echo '{}'; exit 0; }
    cat > /dev/null
    echo '{"data":{"projectTokenCreate":"$PROJECT_TOKEN"}}' ;;
  *secrets.example.com*)
    grep -q "Bearer $INFISICAL_ADMIN_TOKEN" <<<"\$headers" || { printf 401; exit 0; }
    if [[ "\$method" == GET ]]; then printf 404
    else name="\${url##*/}"; cat > "\$BODY_DIR/\$name.json"; printf 200; fi ;;
esac
SH
chmod +x "$BIN"/*

touch "$WORK/test.tfvars"
PATH="$BIN:$PATH" "$SCRIPT" --var-file "$WORK/test.tfvars" --tofu-dir "$WORK" > "$WORK/out.log" 2>&1 \
  || { cat "$WORK/out.log"; echo "FAIL: script exited non-zero"; exit 1; }

fail=0
for secret in "$PROJECT_TOKEN" "$RAILWAY_API_TOKEN" "$INFISICAL_ADMIN_TOKEN"; do
  if grep -qF "$secret" "$ARGV_LOG"; then echo "FAIL: a token appears in process arguments"; fail=1; fi
  if grep -qF "$secret" "$WORK/out.log"; then echo "FAIL: a token appears in the script output"; fail=1; fi
done
for name in RAILWAY_TOKEN_BILLING_API RAILWAY_TOKEN_CRM_API; do
  body="$BODY_DIR/$name.json"
  if [[ ! -f "$body" ]] || [[ "$("$REAL_JQ" -r .secretValue "$body")" != "$PROJECT_TOKEN" ]]; then
    echo "FAIL: $name was not written to Infisical with the token"; fail=1
  fi
done
(( fail )) && exit 1
echo "ok: tokens reached Infisical and never appeared in argv or output ($(wc -l < "$ARGV_LOG") commands checked)"
