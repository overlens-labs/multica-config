#!/usr/bin/env bash
# Refuses OpenTofu code that could run arbitrary commands or reach arbitrary
# hosts while the pipeline holds admin credentials (`tofu plan` in a PR runs
# the PR's code and decrypts the state):
#
#   - `provisioner` blocks of any kind (local-exec, remote-exec, file);
#   - `data "external"` and `data "http"`;
#   - providers outside an allowlist (catches external/http under any alias);
#   - modules not sourced from inside the infra directory;
#   - JSON-syntax config (*.tf.json) and anything that can inject a provider
#     binary: committed `.terraform/` or `terraform.d/` dirs, unexpected files.
#
# The plan workflow runs the copy of this script from the PR's *base* commit
# against the PR's checkout, so a PR can't relax the rules it is checked by.
# Changing the allowlist therefore takes a PR of its own, merged first.
#
# Usage: check-infra-safety.sh [infra-dir]   (default: <repo>/infra)
# Needs tofu on PATH (runs `tofu init -backend=false`, no credentials).
set -euo pipefail

INFRA="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/infra}"
INFRA="$(cd "$INFRA" && pwd)"

ALLOWED_PROVIDERS=(
  registry.opentofu.org/hashicorp/aws
  registry.opentofu.org/infisical/infisical
  registry.opentofu.org/kislerdm/neon
  registry.opentofu.org/integrations/github
)

fail=0
bad() { echo "check-infra-safety: $*" >&2; fail=1; }

# --- 1. Files ---------------------------------------------------------------
# Every file under infra/ (ignoring tofu's own local cache) must be plain text
# of a known kind; directories that OpenTofu treats as plugin sources are out.
while IFS= read -r -d '' path; do
  rel="${path#"$INFRA"/}"
  case "$rel" in
    terraform.d|*/terraform.d) bad "$rel: plugin directories are not allowed" ;;
  esac
done < <(find "$INFRA" -name .terraform -prune -o -type d -print0)

while IFS= read -r -d '' path; do
  rel="${path#"$INFRA"/}"
  case "$rel" in
    *.tf.json) bad "$rel: JSON-syntax config is not allowed (use .tf)" ;;
    *.tf | *.tftest.hcl | *.tfvars | *.md | *.json | .terraform.lock.hcl | */.terraform.lock.hcl | .tflint.hcl | */.tflint.hcl) ;;
    *) bad "$rel: unexpected file type in infra/" ;;
  esac
done < <(find "$INFRA" -name .terraform -prune -o -type f -print0)

# A committed .terraform/ would be reused by `tofu init` (cached providers).
if git -C "$INFRA" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$INFRA" ls-files -- . | grep -Eq '(^|/)\.terraform/'; then
    bad ".terraform/ directories must not be committed"
  fi
fi

# --- 2. Forbidden constructs ------------------------------------------------
# Block labels can't be interpolated, so `local-exec` must appear literally;
# any occurrence fails, comments included. For the rest, `#` and `//` line
# comments are stripped so docs can mention the words; `/* */` is kept (a
# string holding "/*" could otherwise hide code), which errs on failing.
# `data "external"`/`"http"` are also caught by the provider allowlist (step
# 3), which no comment or formatting trick gets around.
strip_line_comments() { sed -E 's@(^|[[:space:]])(#|//).*$@@' "$1"; }
while IFS= read -r -d '' tf; do
  rel="${tf#"$INFRA"/}"
  if grep -Eq '(local|remote)-exec' "$tf"; then
    bad "$rel: local-exec/remote-exec are not allowed"
  fi
  code="$(strip_line_comments "$tf")"
  if grep -Eq '(^|[^A-Za-z0-9_-])provisioner([^A-Za-z0-9_-]|$)' <<<"$code"; then
    bad "$rel: provisioner blocks are not allowed"
  fi
  if grep -Eq '(^|[^A-Za-z0-9_-])data[[:space:]]+"?(external|http)"?([^A-Za-z0-9_-]|$)' <<<"$code"; then
    bad "$rel: data \"external\" / data \"http\" are not allowed"
  fi
done < <(find "$INFRA" -name .terraform -prune -o -type f -name '*.tf' -print0)

# --- 3. Providers and modules, per root module -----------------------------
# A root module is a directory with a lock file. `-lockfile=readonly` makes
# init fail if the config needs a provider that isn't in the lock file, so
# the lock file is the complete provider list.
mapfile -d '' locks < <(find "$INFRA" -name .terraform -prune -o -type f -name .terraform.lock.hcl -print0)
(( ${#locks[@]} > 0 )) || bad "no .terraform.lock.hcl found under $INFRA"

for lock in "${locks[@]}"; do
  root="$(dirname "$lock")"
  rel="${root#"$INFRA"}"; rel="infra${rel}"

  while read -r addr; do
    ok=0
    for allowed in "${ALLOWED_PROVIDERS[@]}"; do
      [[ "$addr" == "$allowed" ]] && ok=1
    done
    (( ok )) || bad "$rel: provider $addr is not in the allowlist"
  done < <(sed -nE 's@^provider "([^"]+)".*@\1@p' "$lock")

  if ! tofu -chdir="$root" init -backend=false -input=false -no-color -lockfile=readonly >/dev/null; then
    bad "$rel: tofu init -lockfile=readonly failed (provider missing from the lock file?)"
    continue
  fi

  modules_json="$root/.terraform/modules/modules.json"
  [[ -f "$modules_json" ]] || continue
  while IFS=$'\t' read -r key src dir; do
    [[ -z "$key" ]] && continue
    case "$src" in
      ./* | ../*) ;;
      *) bad "$rel: module \"$key\" has a non-local source ($src)"; continue ;;
    esac
    abs="$(cd "$root/$dir" 2>/dev/null && pwd)" || abs=""
    case "$abs" in
      "$INFRA" | "$INFRA"/*) ;;
      *) bad "$rel: module \"$key\" points outside infra/ ($src)" ;;
    esac
  done < <(jq -r '.Modules[] | select(.Key != "") | [.Key, .Source, .Dir] | @tsv' "$modules_json")
done

if (( fail )); then
  echo "check-infra-safety: FAILED" >&2
  exit 1
fi
echo "check-infra-safety: ok (${#locks[@]} root module(s))"
