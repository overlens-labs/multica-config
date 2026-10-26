#!/usr/bin/env bash
# Offline test of check-infra-safety.sh: each case builds a tiny infra dir
# (no providers to download) and expects the check to pass or fail.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/scripts/check-infra-safety.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
n=0

# new_infra <name>: minimal valid infra with one root and one local module.
new_infra() {
  local d="$WORK/$1/infra"
  mkdir -p "$d/modules/m"
  printf '# lock\n' >"$d/.terraform.lock.hcl"
  cat >"$d/main.tf" <<'EOF'
# A comment may say provisioner or data "http" without failing.
module "m" {
  source = "./modules/m"
}
EOF
  printf 'output "x" {\n  value = "http://example.com" // url\n}\n' >"$d/modules/m/main.tf"
  echo "$d"
}

expect() { # expect <pass|fail> <description> <infra-dir> [reason regex]
  local want="$1" desc="$2" dir="$3" reason="${4:-}" got
  n=$((n + 1))
  if "$CHECK" "$dir" >"$WORK/out" 2>&1; then got=pass; else got=fail; fi
  if [[ "$got" == "$want" ]] && { [[ -z "$reason" ]] || grep -Eq "$reason" "$WORK/out"; }; then
    echo "ok   $desc"
  else
    echo "FAIL $desc (wanted $want${reason:+ /$reason/}, got $got)"; sed 's/^/     /' "$WORK/out"
    failures=$((failures + 1))
  fi
}

d="$(new_infra clean)"
expect pass "clean infra" "$d"

d="$(new_infra local_exec)"
cat >>"$d/main.tf" <<'EOF'
resource "terraform_data" "x" {
  provisioner "local-exec" {
    command = "env"
  }
}
EOF
expect fail "provisioner local-exec" "$d" 'local-exec'

d="$(new_infra bare_provisioner)"
printf 'resource "terraform_data" "x" {\n  provisioner file {\n    source = "a"\n    destination = "b"\n  }\n}\n' >>"$d/modules/m/main.tf"
expect fail "provisioner with a bare label, inside a module" "$d" 'modules/m/main.tf: provisioner'

d="$(new_infra data_external)"
printf 'data external "x" {\n  program = ["sh"]\n}\n' >>"$d/main.tf"
expect fail "data external (bare label)" "$d" 'data .external'

d="$(new_infra data_http)"
printf 'data "http" "x" {\n  url = "https://example.com"\n}\n' >>"$d/main.tf"
expect fail "data \"http\"" "$d" 'data .external. / data .http'

d="$(new_infra provider_lock)"
printf 'provider "registry.opentofu.org/hashicorp/external" {\n  version = "2.3.4"\n}\n' >>"$d/.terraform.lock.hcl"
expect fail "provider outside the allowlist in the lock file" "$d" 'hashicorp/external is not in the allowlist'

d="$(new_infra tf_json)"
echo '{}' >"$d/extra.tf.json"
expect fail "JSON-syntax config" "$d" 'JSON-syntax'

d="$(new_infra plugin_dir)"
mkdir -p "$d/terraform.d/plugins"
expect fail "terraform.d plugin directory" "$d" 'plugin directories'

d="$(new_infra binary)"
printf '\x7fELF' >"$d/terraform-provider-aws"
expect fail "unexpected file" "$d" 'unexpected file type'

d="$(new_infra outside_module)"
mkdir -p "$WORK/outside_module/evil"
printf 'output "y" {\n  value = 1\n}\n' >"$WORK/outside_module/evil/main.tf"
printf 'module "evil" {\n  source = "../evil"\n}\n' >>"$d/main.tf"
expect fail "module outside infra/" "$d" 'points outside infra'

echo
if (( failures )); then
  echo "check-infra-safety tests: $failures of $n failed"; exit 1
fi
echo "check-infra-safety tests: $n passed"
