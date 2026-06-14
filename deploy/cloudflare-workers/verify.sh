#!/usr/bin/env bash
# Smoke-test the deployed worker.
#
# Usage:
#   ./verify.sh                         (auto-detects URL via `wrangler deployments`)
#   WORKER_URL=https://x.workers.dev ./verify.sh
#
# Checks:
#   - GET /v1/health returns 200
#   - 404 for an unknown path
#   - 401 for a registration-gated POST without a token

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
pass() { printf '\033[32m  ok\033[0m %s\n' "$*"; }
fail() { printf '\033[31m  fail\033[0m %s\n' "$*"; FAIL=1; }

if [[ -z "${WORKER_URL:-}" ]]; then
    log "discovering worker URL via wrangler"
    # wrangler doesn't expose a single-line URL probe; grep the deployments
    # output. The fallback is to ask the user.
    WORKER_URL="$(npx --yes wrangler deployments list 2>/dev/null \
        | grep -oE 'https://[a-zA-Z0-9.-]+\.workers\.dev' \
        | head -1 || true)"
    if [[ -z "$WORKER_URL" ]]; then
        printf "Enter your worker URL (e.g. https://apollo-reborn-notifications.xxx.workers.dev): "
        read -r WORKER_URL
    fi
fi

WORKER_URL="${WORKER_URL%/}"
[[ -n "$WORKER_URL" ]] || die "WORKER_URL not set"
log "verifying $WORKER_URL"

FAIL=0

# ---- 1. health ----
log "GET /v1/health"
status="$(curl -sS -o /tmp/apollo-cf-health.json -w '%{http_code}' "${WORKER_URL}/v1/health")"
if [[ "$status" == "200" ]] && grep -q '"status":"ok"' /tmp/apollo-cf-health.json; then
    pass "health endpoint returned 200 with status=ok"
else
    fail "health endpoint returned $status: $(cat /tmp/apollo-cf-health.json)"
fi

# ---- 2. 404 ----
log "GET /v1/nope (expecting 404)"
status="$(curl -sS -o /dev/null -w '%{http_code}' "${WORKER_URL}/v1/nope")"
[[ "$status" == "404" ]] && pass "unknown path returns 404" || fail "unknown path returned $status"

# ---- 3. registration gate ----
log "POST /v1/device without token (expecting 401)"
status="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "${WORKER_URL}/v1/device" \
    -H "content-type: application/json" \
    -d '{"apns_token":"deadbeef"}')"
[[ "$status" == "401" ]] && pass "missing token returns 401" || fail "missing token returned $status"

# ---- 4. optional: registration gate ACCEPT path ----
if [[ -n "${REGISTRATION_SECRET:-}" ]]; then
    log "POST /v1/device with valid token (expecting 200)"
    status="$(curl -sS -o /dev/null -w '%{http_code}' \
        -X POST "${WORKER_URL}/v1/device" \
        -H "content-type: application/json" \
        -H "x-registration-token: ${REGISTRATION_SECRET}" \
        -d '{"apns_token":"deadbeefverify","sandbox":true}')"
    [[ "$status" == "200" ]] && pass "valid token registers device" || fail "valid token returned $status"

    # Send a test push if APNS_TOKEN is provided.
    if [[ -n "${APNS_TOKEN:-}" ]]; then
        log "POST /v1/device/${APNS_TOKEN:0:8}.../test (expecting 200)"
        status="$(curl -sS -o /tmp/apollo-cf-test.json -w '%{http_code}' \
            -X POST "${WORKER_URL}/v1/device/${APNS_TOKEN}/test" \
            -H "content-type: application/json" \
            -d '{}')"
        if [[ "$status" == "200" ]]; then
            pass "test push accepted"
        else
            fail "test push returned $status: $(cat /tmp/apollo-cf-test.json)"
        fi
    else
        log "(skip) set APNS_TOKEN to also test a real push"
    fi
else
    log "(skip) set REGISTRATION_SECRET env var to also test gated endpoints"
fi

if [[ "$FAIL" == "1" ]]; then
    die "one or more checks failed"
fi
log "all checks passed"
