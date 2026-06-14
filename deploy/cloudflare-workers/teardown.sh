#!/usr/bin/env bash
# Tears down the Cloudflare Workers notifications backend.
#
# Deletes:
#   - the worker itself (wrangler delete)
#   - the D1 database (irreversible)
#
# Requires explicit confirmation. Safe to re-run if a previous teardown was
# partial.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

WORKER_NAME="apollo-reborn-notifications"
DB_NAME="apollo-reborn-notifications"
WRANGLER="npx --yes wrangler"

warn "This will permanently delete:"
warn "  - the worker '$WORKER_NAME' and its secrets"
warn "  - the D1 database '$DB_NAME' (all stored accounts + tokens)"
warn "Configure a fresh backend from scratch with ./deploy.sh"
echo ""
printf "Type the worker name '%s' to confirm: " "$WORKER_NAME"
read -r confirm
[[ "$confirm" == "$WORKER_NAME" ]] || die "confirmation did not match — aborting"

log "deleting worker '$WORKER_NAME'"
if ! $WRANGLER delete --name "$WORKER_NAME"; then
    warn "worker delete failed (may already be gone)"
fi

log "deleting D1 database '$DB_NAME'"
if ! $WRANGLER d1 delete "$DB_NAME"; then
    warn "D1 delete failed (may already be gone)"
fi

log "done. wrangler.toml still references the old database_id — re-run ./deploy.sh to re-create."
