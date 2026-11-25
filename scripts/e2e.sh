#!/usr/bin/env bash
# End-to-end test: deploys the module from this checkout into a real AWS account,
# runs the pytest suite in tests/e2e/suite (auth, uploads, index, cooldown against a fake upstream with
# known upload times, pip/uv/poetry/twine), then tears everything down.
#
# Usage:  scripts/e2e.sh [run|up|test|down]     (default: run = up + test + down)
#         PYTEST_ARGS="-k cooldown" scripts/e2e.sh test   re-runs part of the suite against a deployment kept with KEEP=1
#
# Needs: terraform (or TF=tofu), aws CLI v2, python3 >= 3.9, and AWS credentials for a test account,
# e.g. AWS_PROFILE=my-sandbox AWS_REGION=eu-central-1 scripts/e2e.sh
# Costs a few cents. KEEP=1 skips the teardown after `run`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E2E_DIR="$ROOT/tests/e2e"
TF="${TF:-terraform}"
export AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}"

E2E_USER="e2e"
E2E_PASSWORD="${E2E_PASSWORD:-e2e-$(python3 -c 'import secrets; print(secrets.token_hex(8))')}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
tf() { "$TF" -chdir="$E2E_DIR" "$@"; }
out() { tf output -raw "$1"; }

up() {
  log "Checking AWS credentials"
  aws sts get-caller-identity --query '[Account, Arn]' --output text

  log "Deploying the module to $AWS_REGION"
  tf init -input=false -upgrade >/dev/null
  tf apply -input=false -auto-approve

  log "Setting test credentials in Secrets Manager"
  aws secretsmanager put-secret-value --secret-id "$(out auth_secret_name)" \
    --secret-string "{\"$E2E_USER\": \"$E2E_PASSWORD\"}" >/dev/null
  # Upload credentials are separate: the same user gets a different password
  aws secretsmanager put-secret-value --secret-id "$(out upload_secret_name)" \
    --secret-string "{\"$E2E_USER\": \"upload-$E2E_PASSWORD\"}" >/dev/null
  printf '%s' "$E2E_PASSWORD" >"$E2E_DIR/.e2e-password"

  log "Waiting for CloudFront to finish deploying (usually 5-15 minutes)"
  aws cloudfront wait distribution-deployed --id "$(out cloudfront_distribution_id)"
}

run_tests() {
  log "Installing the test clients (pytest, twine, uv, poetry)"
  python3 -m venv "$WORK/venv"
  "$WORK/venv/bin/pip" -q install --upgrade pip
  "$WORK/venv/bin/pip" -q install -r "$E2E_DIR/requirements.txt"

  log "Running the end-to-end suite (tests/e2e/suite)"
  E2E_PASSWORD="$(cat "$E2E_DIR/.e2e-password")"
  PATH="$WORK/venv/bin:$PATH" \
    E2E_INDEX_URL="$(out index_url)" \
    E2E_USER="$E2E_USER" \
    E2E_PASSWORD="$E2E_PASSWORD" \
    E2E_UPLOAD_URL="$(out upload_url)" \
    E2E_UPLOAD_PASSWORD="upload-$E2E_PASSWORD" \
    E2E_FAKE_UPSTREAM=1 \
    E2E_COOLDOWN_DAYS="$(out cooldown_days)" \
    "$WORK/venv/bin/python" -m pytest "$E2E_DIR/suite" -p no:cacheprovider -ra ${PYTEST_ARGS:-}
}

down() {
  log "Destroying the test deployment"
  if tf destroy -input=false -auto-approve; then
    rm -f "$E2E_DIR/.e2e-password"
    return 0
  fi
  cat <<EOF

Destroy didn't finish. This is expected for Lambda@Edge: AWS deletes the function's edge replicas
a few hours after the CloudFront distribution is gone, and only then can the function be deleted.
Everything else is already removed. Finish the cleanup later with:

  AWS_PROFILE=${AWS_PROFILE:-<profile>} AWS_REGION=$AWS_REGION $0 down
EOF
  return 1
}

case "${1:-run}" in
  up) up ;;
  test) run_tests ;;
  down) down ;;
  run)
    # Tear down even when the deployment fails half-way, so no partial resources are left behind
    set +e
    (
      set -e
      up
    )
    status=$?
    if ((status == 0)); then
      run_tests
      status=$?
    fi
    if [[ "${KEEP:-0}" == "1" ]]; then
      log "KEEP=1: leaving the deployment up. Remove it with: $0 down"
    else
      down || true
    fi
    exit "$status"
    ;;
  *)
    echo "Usage: $0 [run|up|test|down]" >&2
    exit 2
    ;;
esac
