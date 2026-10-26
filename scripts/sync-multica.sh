#!/usr/bin/env bash
# Pushes the OpenTofu outputs to Multica: for every agent in the `agents` map
# it sets the env (only the Infisical machine identity), the Notion MCP, the
# concurrency limit and the skills. Agents are matched by display name.
#
# Secrets: the client secret is read from the `agent_client_secrets` sensitive
# output into memory and handed to configure-agent.sh through its environment
# (never argv, never a file, never printed).
#
# Run by the admin after `tofu apply` and after the manual steps of the
# README (NOTION_TOKEN must already be in /<agent>: configure-agent.sh checks it).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --var-file <org>.tfvars [options]

  --var-file <file>     tfvars used for apply (the backend needs it to find the state)
  --tofu-dir <dir>      default: $REPO_DIR/infra
  --only <agent>        sync only this agent slug (repeatable)
  --runtime-id <id>     create agents missing from Multica on this runtime
                        (bare agent: run multica-bootstrap.sh for instructions)
  --railway             also create missing Railway tokens (scripts/railway-tokens.sh)
  --dry-run             show what would change; secrets stay hidden
USAGE
  exit "${1:-1}"
}

VAR_FILE=""
TOFU_DIR="$REPO_DIR/infra"
ONLY=()
RUNTIME_ID=""
RAILWAY=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --var-file) VAR_FILE="${2:-}"; shift 2 ;;
    --tofu-dir) TOFU_DIR="${2:-}"; shift 2 ;;
    --only) ONLY+=("${2:-}"); shift 2 ;;
    --runtime-id) RUNTIME_ID="${2:-}"; shift 2 ;;
    --railway) RAILWAY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "$VAR_FILE" ]] || usage
VAR_FILE="$(realpath "$VAR_FILE")"
for bin in tofu multica jq; do
  command -v "$bin" >/dev/null || { echo "Required command not found: $bin" >&2; exit 1; }
done

log() { echo "[$(date '+%F %T')] $*"; }
tf_output() { tofu -chdir="$TOFU_DIR" output -var-file="$VAR_FILE" -json "$1"; }

AGENTS_JSON="$(tf_output multica_agents)"
INFISICAL_DOMAIN="$(tf_output infisical_host | jq -r .)/api"
# Kept only in this shell's memory.
SECRETS_JSON="$(tf_output agent_client_secrets)"

MULTICA_AGENTS="$(multica agent list --output json)"
MULTICA_SKILLS="$(multica skill list --output json)"

selected() {
  (( ${#ONLY[@]} == 0 )) && return 0
  local s
  for s in "${ONLY[@]}"; do [[ "$s" == "$1" ]] && return 0; done
  return 1
}

failed=()
for slug in $(jq -r 'keys[]' <<<"$AGENTS_JSON"); do
  selected "$slug" || continue
  agent="$(jq -c --arg s "$slug" '.[$s]' <<<"$AGENTS_JSON")"
  name="$(jq -r .name <<<"$agent")"
  concurrency="$(jq -r .max_concurrent_tasks <<<"$agent")"
  log "== $slug ($name)"

  agent_id="$(jq -r --arg n "$name" '[.[] | select(.name == $n and .archived_at == null)][0].id // empty' <<<"$MULTICA_AGENTS")"
  if [[ -z "$agent_id" ]]; then
    if [[ -z "$RUNTIME_ID" ]]; then
      echo "  Agent \"$name\" not found in Multica. Run multica-bootstrap.sh or pass --runtime-id." >&2
      failed+=("$slug"); continue
    fi
    if (( DRY_RUN )); then
      echo "  (dry-run) would create agent \"$name\" on runtime $RUNTIME_ID"; continue
    fi
    agent_id="$(multica agent create --name "$name" --runtime-id "$RUNTIME_ID" \
      --max-concurrent-tasks "$concurrency" --permission-mode private \
      --description "$name" --output json | jq -r .id)"
    log "  created agent $agent_id"
  fi

  # Env + MCP: reuses configure-agent.sh (login check, env merge, Codex env forwarding).
  secret="$(jq -r --arg s "$slug" '.[$s] // empty' <<<"$SECRETS_JSON")"
  [[ -n "$secret" ]] || { echo "  No client secret in the tofu output for $slug" >&2; failed+=("$slug"); continue; }
  args=(--agent-id "$agent_id"
        --project-id "$(jq -r .infisical_project_id <<<"$agent")"
        --client-id "$(jq -r .client_id <<<"$agent")"
        --credentials-path "$(jq -r .secret_path <<<"$agent")"
        --env "$(jq -r .env <<<"$agent")"
        --domain "$INFISICAL_DOMAIN")
  (( DRY_RUN )) && args+=(--dry-run)
  if ! INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET="$secret" "$REPO_DIR/configure-agent.sh" "${args[@]}"; then
    failed+=("$slug"); unset secret; continue
  fi
  unset secret

  # Concurrency.
  current="$(jq -r --arg id "$agent_id" '.[] | select(.id == $id) | .max_concurrent_tasks // empty' <<<"$MULTICA_AGENTS")"
  if [[ "$current" != "$concurrency" ]]; then
    if (( DRY_RUN )); then echo "  (dry-run) max_concurrent_tasks ${current:-?} -> $concurrency"
    else multica agent update "$agent_id" --max-concurrent-tasks "$concurrency" --output table; fi
  fi

  # Skills (added, never removed: manual assignments are kept).
  skill_ids=()
  for skill in $(jq -r '.skills[]' <<<"$agent"); do
    id="$(jq -r --arg n "$skill" '.[] | select(.name == $n) | .id' <<<"$MULTICA_SKILLS")"
    if [[ -z "$id" ]]; then echo "  Skill \"$skill\" not found in the workspace" >&2; failed+=("$slug"); continue; fi
    skill_ids+=("$id")
  done
  if (( ${#skill_ids[@]} )); then
    if (( DRY_RUN )); then echo "  (dry-run) skills add ${skill_ids[*]}"
    else multica agent skills add "$agent_id" --skill-ids "$(IFS=,; echo "${skill_ids[*]}")" --output table; fi
  fi
done
unset SECRETS_JSON

if (( RAILWAY )); then
  rargs=(--var-file "$VAR_FILE" --tofu-dir "$TOFU_DIR")
  (( DRY_RUN )) && rargs+=(--dry-run)
  "$SCRIPT_DIR/railway-tokens.sh" "${rargs[@]}" || failed+=("railway")
fi

if (( ${#failed[@]} )); then
  echo "Finished with errors: ${failed[*]}" >&2
  exit 1
fi
log "All agents in sync."
