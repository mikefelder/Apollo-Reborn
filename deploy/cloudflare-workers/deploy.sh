#!/usr/bin/env bash
# Bootstraps the Cloudflare Workers notifications backend.
#
# Steps:
#   1. Ensure wrangler is installed and logged in.
#   2. Create the D1 database (idempotent — reuses existing one if found).
#   3. Patch wrangler.toml with the D1 database_id.
#   4. Apply schema.sql to D1.
#   5. Prompt for + set every secret via `wrangler secret put`.
#   6. Deploy.
#
# Re-run safely: every step is idempotent. Secrets you've already set are
# left alone unless you re-enter them.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

# ---- helpers ----
log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- prerequisites ----
command -v node >/dev/null 2>&1 || die "node is required (https://nodejs.org/)"
command -v jq   >/dev/null 2>&1 || die "jq is required (brew install jq)"

if [[ ! -d node_modules ]]; then
    log "installing npm dependencies"
    npm install
fi

WRANGLER="npx --yes wrangler"

# ---- 1. wrangler login ----
if ! $WRANGLER whoami >/dev/null 2>&1; then
    log "wrangler not logged in — opening browser"
    $WRANGLER login
fi
ACCOUNT="$($WRANGLER whoami 2>&1 | awk -F'│' '/Account Name/ {print $2; exit}' | xargs || true)"
log "wrangler account: ${ACCOUNT:-unknown}"

# ---- 2. D1 database ----
DB_NAME="apollo-reborn-notifications"
log "ensuring D1 database '$DB_NAME' exists"

# `wrangler d1 list` returns plain text; grep for the name. If absent, create.
if $WRANGLER d1 list 2>/dev/null | awk '{print $1}' | grep -Fxq "$DB_NAME"; then
    log "D1 database already exists, reusing"
else
    log "creating D1 database"
    $WRANGLER d1 create "$DB_NAME"
fi

# ---- 3. patch wrangler.toml with the database_id ----
DB_INFO="$($WRANGLER d1 info "$DB_NAME" --json 2>/dev/null || true)"
DB_ID="$(echo "$DB_INFO" | jq -r '.uuid // .database_id // empty' 2>/dev/null || true)"

if [[ -z "$DB_ID" || "$DB_ID" == "null" ]]; then
    die "could not resolve D1 database_id for '$DB_NAME' — run 'wrangler d1 info $DB_NAME' to debug"
fi

log "patching wrangler.toml with database_id=$DB_ID"
# macOS sed needs '' after -i; portable form uses a temp file.
TMP="$(mktemp)"
awk -v id="$DB_ID" '
    /^\[\[d1_databases\]\]/ { in_d1=1; print; next }
    in_d1 && /^database_id/ { print "database_id = \"" id "\""; in_d1=0; next }
    /^\[/                   { in_d1=0; print; next }
    { print }
' wrangler.toml > "$TMP"
mv "$TMP" wrangler.toml

# ---- 4. apply schema ----
log "applying schema.sql to D1 (idempotent)"
$WRANGLER d1 execute "$DB_NAME" --remote --file=schema.sql

# ---- 5. secrets ----
secret_set_if_provided() {
    local name="$1" prompt="$2"
    local value=""
    # read -s suppresses terminal echo for passphrases / keys.
    printf "%s [leave empty to skip / reuse existing]: " "$prompt" >&2
    if [[ -t 0 ]]; then
        read -rs value
        printf '\n' >&2
    else
        read -r value
    fi
    if [[ -z "$value" ]]; then
        warn "skipped $name"
        return 0
    fi
    printf '%s' "$value" | $WRANGLER secret put "$name"
}

secret_set_pem() {
    local name="$1" path="${2:-}"
    if [[ -z "$path" ]]; then
        printf "Path to .p8 file (Apple APNs auth key) [skip if already set]: "
        read -r path
        if [[ -z "$path" ]]; then
            warn "skipped $name"
            return 0
        fi
    fi
    [[ -r "$path" ]] || die "cannot read $path"
    < "$path" $WRANGLER secret put "$name"
    log "set $name from $path"
}

log "configuring secrets (press Enter to skip any value you've already set)"
echo "  - APPLE_KEY_PEM   (raw .p8 contents)"
echo "  - APPLE_KEY_ID    (10-char key id from Apple developer portal)"
echo "  - REGISTRATION_SECRET (bearer the tweak will send in X-Registration-Token)"
echo ""

DEFAULT_P8="${HOME}/Code/side/ios/AuthKey_S74P382FAK.p8"
if [[ -r "$DEFAULT_P8" ]]; then
    printf "Found %s — use it as APPLE_KEY_PEM? [Y/n] " "$DEFAULT_P8"
    read -r yn
    if [[ -z "$yn" || "$yn" =~ ^[Yy]$ ]]; then
        secret_set_pem APPLE_KEY_PEM "$DEFAULT_P8"
    else
        secret_set_pem APPLE_KEY_PEM ""
    fi
else
    secret_set_pem APPLE_KEY_PEM ""
fi

secret_set_if_provided APPLE_KEY_ID         "APPLE_KEY_ID (e.g. S74P382FAK)"

# Generate a 32-byte random base64 token for REGISTRATION_SECRET if the user
# doesn't have one yet.
log "generating a fresh REGISTRATION_SECRET (32 bytes, base64)"
GEN_SECRET="$(node -e 'console.log(require("crypto").randomBytes(32).toString("base64url"))')"
echo ""
printf "REGISTRATION_SECRET candidate:\n  %s\n" "$GEN_SECRET"
printf "Press Enter to use this, or paste your own (will not echo): "
if [[ -t 0 ]]; then
    read -rs supplied
    printf '\n'
else
    read -r supplied
fi
to_set="${supplied:-$GEN_SECRET}"
printf '%s' "$to_set" | $WRANGLER secret put REGISTRATION_SECRET
echo ""
log "REGISTRATION_SECRET set. Paste this value into:"
log "  Apollo Settings → Custom API → Notification Backend → Registration Token"
echo "  $to_set"
echo ""

# ---- 6. deploy ----
log "deploying worker"
$WRANGLER deploy

log "done. configure the tweak to point at your worker's URL:"
log "  Settings → Custom API → Notification Backend → URL"
log "Run ./verify.sh to smoke-test the deployment."
