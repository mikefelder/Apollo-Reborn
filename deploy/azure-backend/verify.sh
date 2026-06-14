#!/usr/bin/env bash
# Post-deploy verification helper. Run after deploy.sh succeeds AND after you
# configure the tweak on your iPhone + sign in to Reddit at least once.
#
# Checks:
#   1. Health endpoint returns {"status":"available"}
#   2. Tails the last 50 lines of API logs (look for /v1/device/* POSTs)
#   3. Tails the last 50 lines of notifications-worker logs (Reddit polls)
#   4. Prints a curl one-liner for firing a test push

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

command -v terraform >/dev/null || { echo "terraform not installed"; exit 1; }
[[ -f terraform.tfstate ]]      || { echo "No terraform.tfstate — run ./deploy.sh first."; exit 1; }

API_FQDN="$(terraform output -raw api_fqdn)"
HEALTH_URL="$(terraform output -raw health_url)"
REG_TOKEN="$(terraform output -raw registration_secret)"
RG="$(terraform output -raw resource_group_name)"
PG_FQDN="$(terraform output -raw postgres_server_fqdn)"
PG_SERVER="${PG_FQDN%%.*}"

c_blue=$'\033[1;34m'
c_green=$'\033[1;32m'
c_yellow=$'\033[1;33m'
c_dim=$'\033[2m'
c_reset=$'\033[0m'

log() { echo -e "${c_blue}==>${c_reset} $*"; }
ok()  { echo -e "${c_green}✓${c_reset} $*"; }

# --- 1. Health endpoint -----------------------------------------------------

log "Checking ${HEALTH_URL}"
RESP="$(curl -fsS --max-time 10 "${HEALTH_URL}")"
echo "    ${RESP}"
ok "API reachable"

# --- 2. Recent API logs -----------------------------------------------------

log "Last 50 lines of apollo-api logs:"
az containerapp logs show \
  --name apollo-api \
  --resource-group "${RG}" \
  --tail 50 \
  --format text 2>/dev/null || echo "  (no logs yet — app may still be warming up)"

# --- 3. Recent notifications worker logs ------------------------------------

echo
log "Last 50 lines of apollo-worker-notifications logs:"
az containerapp logs show \
  --name apollo-worker-notifications \
  --resource-group "${RG}" \
  --tail 50 \
  --format text 2>/dev/null || echo "  (no logs yet — app may still be warming up)"

# --- 4. Test push instructions ----------------------------------------------

cat <<EOF

${c_yellow}--- Inspect device + account rows ---${c_reset}

After registering a device (sign in to your Reddit account from the Apollo
build with the backend configured), pull the APNs token from the database
by temporarily opening the Postgres firewall to your laptop:

  ${c_dim}# 1. Allow your laptop's IP through the firewall (one-time):${c_reset}
  MY_IP=\$(curl -s https://api.ipify.org)
  az postgres flexible-server firewall-rule create \\
    -g ${RG} -n ${PG_SERVER} \\
    --rule-name laptop --start-ip-address \$MY_IP --end-ip-address \$MY_IP

  ${c_dim}# 2. Query device + account rows (password from terraform output):${c_reset}
  PG_PASS=\$(terraform output -raw postgres_admin_password)
  PSQL_URL="postgres://apolloadmin:\$PG_PASS@${PG_FQDN}:5432/apollo?sslmode=require"
  psql "\$PSQL_URL" -c "SELECT id, sandbox, apns_token FROM devices ORDER BY id DESC LIMIT 5;"
  psql "\$PSQL_URL" -c "SELECT id, username, check_count FROM accounts ORDER BY id DESC LIMIT 5;"

  ${c_dim}# 3. When you're done, remove the firewall hole:${c_reset}
  az postgres flexible-server firewall-rule delete \\
    -g ${RG} -n ${PG_SERVER} --rule-name laptop --yes

${c_yellow}--- Fire a test push manually ---${c_reset}

  curl -X POST \\
    -H "X-Registration-Token: ${REG_TOKEN}" \\
    https://${API_FQDN}/v1/device/<apns-token>/test/post_reply

${c_yellow}--- Warmup gotcha ---${c_reset}

The very first inbox message after registration is silently consumed by the
worker (it sets check_count=1 to bootstrap the per-account cursor). To skip
that and have the next message push immediately:

  UPDATE accounts SET check_count = 1 WHERE username = '<your_username>';

EOF
