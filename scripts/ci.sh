#!/usr/bin/env bash
# Static checks for this repo, the same locally and in CI. Touches no real
# account: no backend, no state encryption, mocked providers only.
#
# Needs on PATH: tofu (>= 1.9), shellcheck, jq, python3; tflint is optional
# locally (skipped with a warning) and required when CI=true.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

step() { echo; echo "==> $*"; }

step "tofu fmt"
tofu -chdir=infra fmt -check -recursive

# Two root modules: the main stack (applied by the pipeline) and the App
# installations (applied locally by an org owner; see infra/README.md).
for root in infra infra/app-installations; do
  step "$root: tofu init (no backend) + validate"
  tofu -chdir="$root" init -backend=false -input=false -no-color >/dev/null
  tofu -chdir="$root" validate -no-color

  step "$root: tofu test (mocked providers)"
  tofu -chdir="$root" test -no-color
done

step "infra safety (no provisioners, external/http, foreign providers or modules)"
scripts/check-infra-safety.sh infra
scripts/tests/check-infra-safety.test.sh

step "tflint"
if command -v tflint >/dev/null; then
  (cd infra && tflint --init >/dev/null && tflint --recursive)
elif [[ "${CI:-}" == "true" ]]; then
  echo "tflint is required in CI" >&2; exit 1
else
  echo "tflint not installed; skipped"
fi

step "shellcheck"
shellcheck ./*.sh scripts/*.sh scripts/tests/*.sh

step "railway-tokens offline test"
scripts/tests/railway-tokens.test.sh

step "python unittest"
python3 -I -B -m unittest discover -s scripts/tests

echo; echo "All checks passed."
