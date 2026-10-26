#!/usr/bin/env bash
# Creates Railway project tokens (scoped to the dev environment) for the
# agents and writes each one straight to Infisical as RAILWAY_TOKEN_<KEY> in
# /<agent>. The community Railway provider has no project-token resource, so
# this runs outside OpenTofu (see infra/README.md).
#
# Idempotent: an existing RAILWAY_TOKEN_<KEY> is left alone unless --rotate.
# Tokens never touch argv, files or stdout.
#
# Admin environment:
#   RAILWAY_API_TOKEN                          account/team token of the admin
#   INFISICAL_UNIVERSAL_AUTH_CLIENT_ID/_SECRET admin identity (same as for tofu)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAILWAY_API="https://backboard.railway.com/graphql/v2"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --var-file <org>.tfvars [--tofu-dir <dir>] [--rotate] [--dry-run]
USAGE
  exit "${1:-1}"
}

VAR_FILE=""
TOFU_DIR="$(dirname "$SCRIPT_DIR")/infra"
ROTATE=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --var-file) VAR_FILE="${2:-}"; shift 2 ;;
    --tofu-dir) TOFU_DIR="${2:-}"; shift 2 ;;
    --rotate) ROTATE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done
[[ -n "$VAR_FILE" ]] || usage
VAR_FILE="$(realpath "$VAR_FILE")"
for bin in tofu infisical curl jq; do
  command -v "$bin" >/dev/null || { echo "Required command not found: $bin" >&2; exit 1; }
done

log() { echo "[$(date '+%F %T')] $*"; }
tf_output() { tofu -chdir="$TOFU_DIR" output -var-file="$VAR_FILE" -json "$1"; }

PLAN="$(tf_output railway_tokens)"
if [[ "$(jq length <<<"$PLAN")" == 0 ]]; then
  log "No Railway tokens declared."; exit 0
fi
INFISICAL_API="$(tf_output infisical_host | jq -r .)/api"

[[ -n "${RAILWAY_API_TOKEN:-}" ]] || { echo "RAILWAY_API_TOKEN is not set" >&2; exit 1; }
INFISICAL_TOKEN="$(infisical login --method=universal-auth --domain="$INFISICAL_API" --silent --plain)" || true
[[ -n "$INFISICAL_TOKEN" ]] || { echo "Infisical universal-auth login failed (admin identity)" >&2; exit 1; }

# Auth headers go through process substitution, so tokens stay out of argv.
infisical_api() { # method path [curl args...]
  local method="$1" path="$2"; shift 2
  curl -sS -o /dev/null -w '%{http_code}' -X "$method" \
    -H @<(printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$INFISICAL_TOKEN") \
    "$INFISICAL_API$path" "$@"
}

failed=0
while read -r item; do
  agent="$(jq -r .agent <<<"$item")"
  name="RAILWAY_TOKEN_$(jq -r .key <<<"$item")"
  project="$(jq -r .infisical_project_id <<<"$item")"
  path="$(jq -r .secret_path <<<"$item")"
  query="workspaceId=$project&environment=dev&secretPath=$(jq -rn --arg p "$path" '$p|@uri')"

  exists=0
  [[ "$(infisical_api GET "/v3/secrets/raw/$name?$query")" == 200 ]] && exists=1
  if (( exists && !ROTATE )); then
    log "$agent: $name already in Infisical, skipping (use --rotate to replace)"; continue
  fi
  if (( DRY_RUN )); then
    log "$agent: (dry-run) would create a Railway token and $( ((exists)) && echo update || echo create ) $name"; continue
  fi

  token="$(jq -n --arg p "$(jq -r .project_id <<<"$item")" --arg e "$(jq -r .environment_id <<<"$item")" --arg n "agent-$agent" '{
      query: "mutation($input: ProjectTokenCreateInput!) { projectTokenCreate(input: $input) }",
      variables: { input: { projectId: $p, environmentId: $e, name: $n } }
    }' | curl -sS -X POST "$RAILWAY_API" \
      -H @<(printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$RAILWAY_API_TOKEN") \
      --data-binary @- | jq -r '.data.projectTokenCreate // empty')"
  if [[ -z "$token" ]]; then
    echo "$agent: Railway did not return a token for $name" >&2; failed=1; continue
  fi

  method=POST; (( exists )) && method=PATCH
  code="$(jq -n --arg w "$project" --arg p "$path" --arg v "$token" \
      '{workspaceId: $w, environment: "dev", secretPath: $p, secretValue: $v, type: "shared"}' \
    | infisical_api "$method" "/v3/secrets/raw/$name" --data-binary @-)"
  unset token
  if [[ "$code" != 200 ]]; then
    echo "$agent: writing $name to Infisical failed (HTTP $code). Delete the orphan token agent-$agent in Railway." >&2
    failed=1; continue
  fi
  log "$agent: $name written to Infisical ($path)"
done < <(jq -c '.[]' <<<"$PLAN")

unset INFISICAL_TOKEN
exit "$failed"
