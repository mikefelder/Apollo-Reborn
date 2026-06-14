#!/usr/bin/env bash
# Tear down the Apollo backend via terraform destroy.
#
# Removes every resource Terraform created:
#   - All 9 container apps (api, scheduler, redis, 6 workers)
#   - Migration job
#   - Container Apps environment
#   - Log Analytics workspace
#   - Postgres Flex Server (and all data)
#   - Resource group itself
#
# IRREVERSIBLE. Won't touch your APNs key or anything outside this state file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

command -v terraform >/dev/null || { echo "terraform not installed"; exit 1; }

if [[ ! -f terraform.tfstate ]]; then
  echo "No terraform.tfstate found — nothing to destroy."
  echo "If the resource group exists but state is missing, delete manually:"
  echo "  az group delete --name apollo-backend-rg --yes --no-wait"
  exit 0
fi

# Reuse az CLI auth (same as deploy.sh).
if az account show >/dev/null 2>&1; then
  ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
  ARM_TENANT_ID="$(az account show --query tenantId -o tsv)"
  export ARM_SUBSCRIPTION_ID ARM_TENANT_ID
else
  echo "Not signed in to Azure CLI. Run: az login"
  exit 1
fi

RG="$(terraform output -raw resource_group_name 2>/dev/null || echo apollo-backend-rg)"

c_red=$'\033[1;31m'
c_yellow=$'\033[1;33m'
c_reset=$'\033[0m'

echo -e "${c_red}WARNING:${c_reset} this will delete resource group ${c_yellow}${RG}${c_reset} and every resource Terraform manages."
read -rp "Type the resource group name to confirm: " CONFIRM
[[ "${CONFIRM}" == "${RG}" ]] || { echo "Cancelled."; exit 1; }

# Terraform requires every variable to resolve even on destroy. Re-export
# stub values for any input the operator didn't set in their shell — they're
# not actually used to compute the destroy plan.
export TF_VAR_apple_apns_topic="${TF_VAR_apple_apns_topic:-com.example.placeholder}"
export TF_VAR_apple_team_id="${TF_VAR_apple_team_id:-PLACEHOLD0}"
export TF_VAR_apple_key_id="${TF_VAR_apple_key_id:-PLACEHOLD0}"
export TF_VAR_apple_key_pem="${TF_VAR_apple_key_pem:-stub}"
export TF_VAR_reddit_client_id="${TF_VAR_reddit_client_id:-stub}"
export TF_VAR_reddit_user_agent="${TF_VAR_reddit_user_agent:-ios:stub:v1.0 (by /u/stub)}"

terraform destroy -auto-approve -input=false

cat <<EOF

Resources destroyed. State file (terraform.tfstate*) is preserved in case you
want to inspect previous values. Remove it for a fully clean slate:
  rm -f terraform.tfstate terraform.tfstate.backup
EOF
