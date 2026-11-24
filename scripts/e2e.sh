#!/usr/bin/env bash
# End-to-end test: deploys the module from this checkout into a real AWS account, publishes a tiny package
# with twine, checks uploads, the index with curl and pip, then tears everything down.
#
# Usage:  scripts/e2e.sh [run|up|test|down]     (default: run = up + test + down)
#
# Needs: terraform (or TF=tofu), aws CLI v2, curl, python3 >= 3.9, and AWS credentials for a test account,
# e.g. AWS_PROFILE=my-sandbox AWS_REGION=eu-central-1 scripts/e2e.sh
# Costs a few cents. KEEP=1 skips the teardown after `run`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E2E_DIR="$ROOT/tests/e2e"
TF="${TF:-terraform}"
export AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}"

E2E_USER="e2e"
E2E_PASSWORD="${E2E_PASSWORD:-e2e-$(python3 -c 'import secrets; print(secrets.token_hex(8))')}"
PKG_NAME="e2e-demo"
PKG_VERSION="0.0.$(date +%s)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=$((FAILED + 1)); }
tf() { "$TF" -chdir="$E2E_DIR" "$@"; }
out() { tf output -raw "$1"; }

# Usage: check "description" expected_status url [curl args...]
check_status() {
  local desc="$1" expected="$2" url="$3"
  shift 3
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' "$@" "$url")"
  if [[ "$status" == "$expected" ]]; then pass "$desc ($status)"; else fail "$desc: expected $expected, got $status"; fi
}

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

publish_package() {
  log "Building and uploading $PKG_NAME $PKG_VERSION"
  local src="$WORK/pkg"
  mkdir -p "$src/e2e_demo"
  cat >"$src/pyproject.toml" <<EOF
[build-system]
requires = ["setuptools>=61"]
build-backend = "setuptools.build_meta"

[project]
name = "$PKG_NAME"
version = "$PKG_VERSION"
EOF
  printf '__version__ = "%s"\n' "$PKG_VERSION" >"$src/e2e_demo/__init__.py"

  python3 -m venv "$WORK/venv"
  "$WORK/venv/bin/pip" -q install --upgrade pip twine
  "$WORK/venv/bin/pip" -q wheel --no-deps -w "$WORK/dist" "$src"

  local wheel upload_url upload_auth
  wheel="$(ls "$WORK/dist"/*.whl)"
  WHEEL_FILE="$(basename "$wheel")"
  upload_url="$(out upload_url)"
  upload_auth="$E2E_USER:upload-$E2E_PASSWORD"

  # The read password must not be accepted for uploads
  check_status "upload with the read password is rejected" 401 "$upload_url" -u "$E2E_USER:$E2E_PASSWORD" \
    -F ":action=file_upload" -F "name=$PKG_NAME" -F "content=@$wheel"

  if "$WORK/venv/bin/twine" upload --non-interactive --repository-url "$upload_url" \
    -u "$E2E_USER" -p "upload-$E2E_PASSWORD" "$wheel"; then
    pass "twine upload $WHEEL_FILE"
  else
    fail "twine upload $WHEEL_FILE"
  fi

  check_status "re-uploading the same file succeeds" 200 "$upload_url" -u "$upload_auth" \
    -F ":action=file_upload" -F "name=$PKG_NAME" -F "content=@$wheel"
  printf 'different content' >"$WORK/other.whl"
  check_status "overwriting a file with different content is refused" 409 "$upload_url" -u "$upload_auth" \
    -F ":action=file_upload" -F "name=$PKG_NAME" -F "content=@$WORK/other.whl;filename=$WHEEL_FILE"
}

run_tests() {
  E2E_PASSWORD="$(cat "$E2E_DIR/.e2e-password")"
  local index host auth
  index="$(out index_url)"
  host="${index#https://}"
  host="${host%%/*}"
  auth="$E2E_USER:$E2E_PASSWORD"

  publish_package

  # Give the invalidation a moment; index TTL is 5 s anyway
  sleep 15

  log "Authentication"
  check_status "index without credentials is rejected" 401 "$index"
  check_status "index with a wrong password is rejected" 401 "$index" -u "$E2E_USER:wrong"
  check_status "package file without credentials is rejected" 401 "https://$host/$PKG_NAME/$WHEEL_FILE"
  check_status "index with valid credentials" 200 "$index" -u "$auth"

  log "PEP 503 index"
  if curl -sf -u "$auth" "$index" | grep -q "href=\"$PKG_NAME/\""; then
    pass "root index lists $PKG_NAME"
  else
    fail "root index doesn't list $PKG_NAME"
  fi
  if curl -sf -u "$auth" "${index}${PKG_NAME}/" | grep -q "$WHEEL_FILE"; then
    pass "package page links $WHEEL_FILE"
  else
    fail "package page doesn't link $WHEEL_FILE"
  fi
  check_status "package file download (S3 origin via OAC)" 200 "https://$host/$PKG_NAME/$WHEEL_FILE" -u "$auth"
  check_status "unknown package (not on pypi.org either)" 404 "${index}e2e-no-such-package-$RANDOM/" -u "$auth"

  log "Cooldown"
  local page
  page="$(curl -s --compressed -u "$auth" "${index}requests/")"
  # pypi.org's own pages carry a pypi:repository-version meta tag; pages built by the cooldown don't
  if grep -q 'requests-2' <<<"$page" && ! grep -q 'pypi:repository-version' <<<"$page"; then
    pass "upstream page for requests is built by the cooldown"
  else
    fail "upstream page for requests isn't generated by the cooldown"
  fi
  if curl -s --compressed -u "$auth" "${index}six/" | grep -q 'pypi:repository-version'; then
    pass "excluded package six is proxied straight from upstream"
  else
    fail "excluded package six isn't served"
  fi

  log "Security headers"
  if curl -sI -u "$auth" "$index" | grep -qi '^strict-transport-security:'; then
    pass "HSTS header present"
  else
    fail "HSTS header missing"
  fi

  log "pip"
  local pip_index="https://$auth@$host/simple/"
  if "$WORK/venv/bin/pip" install -q --no-cache-dir --index-url "$pip_index" "$PKG_NAME==$PKG_VERSION" &&
    [[ "$("$WORK/venv/bin/python" -c 'import e2e_demo; print(e2e_demo.__version__)')" == "$PKG_VERSION" ]]; then
    pass "pip install $PKG_NAME==$PKG_VERSION from the private index"
  else
    fail "pip install $PKG_NAME from the private index"
  fi
  if "$WORK/venv/bin/pip" download -q --no-cache-dir --no-deps -d "$WORK/upstream" --index-url "$pip_index" requests; then
    pass "pip download requests through the pypi.org fallback"
  else
    fail "pip download requests through the pypi.org fallback"
  fi

  log "Result"
  if ((FAILED > 0)); then
    printf '\033[31m%d check(s) failed\033[0m\n' "$FAILED"
    return 1
  fi
  printf '\033[32mAll checks passed\033[0m\n'
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
