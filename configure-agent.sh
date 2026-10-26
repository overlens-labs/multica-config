#!/usr/bin/env bash
# Injects Infisical credentials and the Notion MCP config into a Multica agent.
#
# The client secret is never taken as an argument (it would leak into shell
# history and `ps`): it is read from $INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET
# when set, otherwise prompted for without echo.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Required:
  --agent-id <AGENT_ID>
  --project-id <INFISICAL_PROJECT_ID>
  --client-id <INFISICAL_UNIVERSAL_AUTH_CLIENT_ID>
  --credentials-path <INFISICAL_CREDENTIALS_PATH>   e.g. /pe-backend

Optional:
  --domain <INFISICAL_DOMAIN>   default: https://secrets.overlens.com.br/api
  --env <INFISICAL_ENV>         default: dev
  --dry-run                     validate and print the configs (secret masked), change nothing

Client secret: env INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET, or interactive prompt.
USAGE
  exit "${1:-1}"
}

need_value() { [[ $# -ge 2 && -n "$2" ]] || { echo "Missing value for $1" >&2; usage; }; }

AGENT_ID=""
INFISICAL_PROJECT_ID=""
INFISICAL_DOMAIN="https://secrets.overlens.com.br/api"
INFISICAL_ENV="dev"
INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=""
INFISICAL_CREDENTIALS_PATH=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent-id) need_value "$@"; AGENT_ID="$2"; shift 2 ;;
    --project-id) need_value "$@"; INFISICAL_PROJECT_ID="$2"; shift 2 ;;
    --domain) need_value "$@"; INFISICAL_DOMAIN="$2"; shift 2 ;;
    --env) need_value "$@"; INFISICAL_ENV="$2"; shift 2 ;;
    --client-id) need_value "$@"; INFISICAL_UNIVERSAL_AUTH_CLIENT_ID="$2"; shift 2 ;;
    --credentials-path) need_value "$@"; INFISICAL_CREDENTIALS_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

missing=()
[[ -z "$AGENT_ID" ]] && missing+=(--agent-id)
[[ -z "$INFISICAL_PROJECT_ID" ]] && missing+=(--project-id)
[[ -z "$INFISICAL_UNIVERSAL_AUTH_CLIENT_ID" ]] && missing+=(--client-id)
[[ -z "$INFISICAL_CREDENTIALS_PATH" ]] && missing+=(--credentials-path)
if (( ${#missing[@]} )); then
  echo "Missing required arguments: ${missing[*]}" >&2
  usage
fi
[[ "$INFISICAL_CREDENTIALS_PATH" == /* ]] || INFISICAL_CREDENTIALS_PATH="/$INFISICAL_CREDENTIALS_PATH"

for bin in multica infisical python3 notion-mcp-server; do
  command -v "$bin" >/dev/null || { echo "Required command not found: $bin" >&2; exit 1; }
done

if [[ -z "${INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET:-}" ]]; then
  read -r -s -p "Client Secret: " INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET; echo
fi
[[ -n "$INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET" ]] || { echo "Empty client secret" >&2; exit 1; }

export INFISICAL_DOMAIN INFISICAL_UNIVERSAL_AUTH_CLIENT_ID INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET \
  INFISICAL_PROJECT_ID INFISICAL_ENV INFISICAL_CREDENTIALS_PATH

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
umask 077

echo "[$(date '+%F %T')] Configuring agent $AGENT_ID (path $INFISICAL_CREDENTIALS_PATH, env $INFISICAL_ENV)"

# 1. Fail fast: the identity must log in and see NOTION_TOKEN at the given path.
T="$(infisical login --method=universal-auth --silent --plain)" || true
[[ -n "$T" ]] || { echo "Infisical universal-auth login failed" >&2; exit 1; }
# The token goes through the environment, never argv (argv is visible via `ps`).
# shellcheck disable=SC2016  # NOTION_TOKEN must expand inside the child shell
if ! INFISICAL_TOKEN="$T" infisical run --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENV" \
     --path="$INFISICAL_CREDENTIALS_PATH" --silent -- sh -c '[ -n "${NOTION_TOKEN:-}" ]'; then
  echo "NOTION_TOKEN not readable at $INFISICAL_CREDENTIALS_PATH ($INFISICAL_ENV)" >&2
  exit 1
fi
unset T
echo "Infisical check OK"

# 2. custom_env: merge with what the agent already has. `env set` replaces the
#    whole map; existing keys are sent as '****', which preserves their values.
multica agent env get "$AGENT_ID" --output json > "$WORK_DIR/current-env.json"
python3 - "$WORK_DIR/current-env.json" > "$WORK_DIR/env.json" <<'PY'
import json, os, sys
current = json.load(open(sys.argv[1])) or {}
env = {k: "****" for k in current}
for k in ("INFISICAL_DOMAIN", "INFISICAL_UNIVERSAL_AUTH_CLIENT_ID", "INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET"):
    env[k] = os.environ[k]
print(json.dumps(env))
PY
rm -f "$WORK_DIR/current-env.json"

# 3. mcp_config: the Notion server fetches its token from Infisical at startup.
#    Note: `agent update --mcp-config-file` replaces the agent's whole mcp_config.
#    Codex starts MCP servers with a filtered environment, so on Codex runtimes
#    the Infisical variables must be forwarded explicitly via `env_vars`.
RUNTIME_ID="$(multica agent get "$AGENT_ID" --output json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("runtime_id") or "")')"
PROVIDER="$(multica runtime list --output json | python3 -c 'import json,sys; rid=sys.argv[1]; print(next((r.get("provider","") for r in json.load(sys.stdin) if r["id"]==rid), ""))' "$RUNTIME_ID")"
export PROVIDER
echo "Runtime provider: ${PROVIDER:-unknown}"
python3 > "$WORK_DIR/config.json" <<'PY'
import json, os, shlex
cmd = (
    'INFISICAL_TOKEN=$(infisical login --method=universal-auth --silent --plain) && '
    '[ -n "$INFISICAL_TOKEN" ] && export INFISICAL_TOKEN && '
    'exec infisical run'
    f' --projectId={shlex.quote(os.environ["INFISICAL_PROJECT_ID"])}'
    f' --env={shlex.quote(os.environ["INFISICAL_ENV"])}'
    f' --path={shlex.quote(os.environ["INFISICAL_CREDENTIALS_PATH"])}'
    ' -- notion-mcp-server'
)
server = {"command": "sh", "args": ["-c", cmd]}
if os.environ.get("PROVIDER") == "codex":
    server["env_vars"] = ["INFISICAL_DOMAIN", "INFISICAL_UNIVERSAL_AUTH_CLIENT_ID", "INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET"]
print(json.dumps({"mcpServers": {"notion": server}}))
PY

if (( DRY_RUN )); then
  echo "--- custom_env (dry run) ---"
  python3 -c 'import json,sys; e=json.load(open(sys.argv[1])); e["INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET"]="<hidden>"; print(json.dumps(e, indent=2))' "$WORK_DIR/env.json"
  echo "--- mcp_config (dry run) ---"
  python3 -m json.tool "$WORK_DIR/config.json"
  exit 0
fi

multica agent env set "$AGENT_ID" --custom-env-file "$WORK_DIR/env.json" --output table
multica agent update "$AGENT_ID" --mcp-config-file "$WORK_DIR/config.json" --output table
echo "[$(date '+%F %T')] Done: agent $AGENT_ID"
