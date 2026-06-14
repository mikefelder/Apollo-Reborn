# Azure deployment — Apollo Reborn push backend (Terraform)

Terraform stack that stands up [Apollo-Reborn/apollo-backend](https://github.com/Apollo-Reborn/apollo-backend) on Azure Container Apps as a single-tenant push-notification service for a sideloaded Apollo build.

This is a thin, opinionated wrapper around the upstream backend. It exists because Phase 8 of [SIDELOAD-GUIDE.md](../../SIDELOAD-GUIDE.md) needs a real "click here to deploy" answer for users who already have an Azure subscription handy. **Nothing in this directory modifies the tweak itself** — it only deploys the backend the tweak's [`ApolloNotificationBackend.m`](../../src/ApolloNotificationBackend.m) already knows how to talk to.

## What it deploys

| Resource | SKU | Why |
| --- | --- | --- |
| Resource group | n/a | Owns the deployment for clean teardown via `terraform destroy` |
| Log Analytics workspace | PerGB2018 | Free 5 GB/day; required by Container Apps for log destination |
| Postgres Flexible Server | Burstable **B1ms** (2 vCore, 32 GB) | Built-in PgBouncer on :6432 → no separate pooler container needed |
| Container Apps environment | Consumption | Per-second billing, scale-to-zero capable, TCP-ingress capable |
| `apollo-redis` | `redis:7-alpine` container app, internal TCP ingress | Queue (DB 0) + locks (DB 1) — README explicitly OKs sharing |
| `apollo-api` | container app, public HTTPS ingress on :4000 | Public entry point the tweak talks to |
| `apollo-scheduler` | container app, no ingress, **1 replica** | The 5s ticker — must be single-instance |
| `apollo-worker-*` × 6 | container apps, no ingress | One per rmq queue: notifications, stuck-notifications, subreddits, trending, users, live-activities |
| `apollo-migrate` | Container Apps Job (Manual) | Idempotent schema bootstrap, safe to re-run |

### Realistic monthly cost

Derived from current Azure list prices ([Container Apps Consumption](https://azure.microsoft.com/en-us/pricing/details/container-apps/), [Postgres Flexible Server](https://azure.microsoft.com/en-us/pricing/details/postgresql/flexible-server/)) against this stack's always-on footprint of **4.0 vCPU + 8.0 GiB RAM** across 9 container replicas:

| Item | Calc | Monthly |
| --- | --- | --- |
| Postgres B1ms | flat | $12.41 |
| Postgres storage 32 GB | 32 × $0.115 | $3.68 |
| Container Apps compute (mixed active/idle, single-user) | ~90% idle for inbox-only volume | ~$110 |
| Log Analytics ingest | ~1–2 GB/mo | ~$3 |
| Container Apps requests | within 2M free | $0 |
| **Total at single-user volume** | | **~$130/mo** |
| **Worst case (all replicas always-active)** | | **~$325/mo** |

Visual Studio Enterprise's $150/mo credit covers single-user volume, but this is genuinely over-provisioned for one person. The architecture mirrors apollo-backend's docker-compose, which was tuned for a public instance serving thousands.

If you want it cheaper without leaving Azure Container Apps:

1. **Drop unused queues** — remove `subreddits`, `trending`, `users`, `live-activities` from `local.workers` in [main.tf](main.tf) if you only need inbox push.
2. **Right-size containers** — change `cpu = 0.5` / `memory = "1Gi"` → `cpu = 0.25` / `memory = "0.5Gi"` in [api.tf](api.tf) and [worker.tf](worker.tf).

Applied together, that lands around **~$50/mo**. For a cheaper alternative architecture see the `feature/notifications-cloudflare-workers` branch (~$0/mo within Cloudflare free tier).

## Prerequisites

1. **Paid Apple Developer account** with `aps-environment` entitlement on your bundle ID.
2. **APNs Auth Key** (`.p8`) from `developer.apple.com → Certificates, IDs & Profiles → Keys`. Note the Key ID + Team ID. *One-time download — you cannot re-download a `.p8`; save it somewhere safe.*
3. **Custom bundle ID** for your sideloaded build (NOT `com.christianselig.Apollo` — Reddit's WAF hard-blocks that string in UAs on `oauth.reddit.com`).
4. **Reddit OAuth credentials** registered at <https://www.reddit.com/prefs/apps> against your custom bundle ID, with redirect URI `apollo://reddit-oauth`.
5. **Tools** (macOS):

   ```bash
   brew install azure-cli terraform
   ```

6. **Azure CLI signed in:** `az login`. Optional: `az account set --subscription <id>` to pin a specific subscription.

## Quickstart

```bash
cd deploy/azure-backend

# Set once per shell (or let deploy.sh prompt you):
export APPLE_APNS_TOPIC=com.yourname.apollo
export APPLE_TEAM_ID=XXXXXXXXXX          # 10 chars
export APPLE_KEY_ID=YYYYYYYYYY            # 10 chars, matches AuthKey_YYYYYYYYYY.p8
export APPLE_KEY_PATH=~/path/to/AuthKey_YYYYYYYYYY.p8
export REDDIT_USER_AGENT='ios:com.yourname.apollo:v1.0 (by /u/yourname)'

./deploy.sh
```

Takes 5–8 minutes. At the end it prints your backend URL and registration token. Configure the tweak on your iPhone (**Settings → Custom API → Notification Backend**) with those two values, tap **Test Connection**, then force-quit Apollo and reopen + re-sign-in once so a device + account row land in Postgres.

Verify with:

```bash
./verify.sh
```

## What deploy.sh handles

- Pre-flight: checks `terraform` + `az` are installed, you're signed in, and the required Azure providers are registered.
- Exports `ARM_SUBSCRIPTION_ID` / `ARM_TENANT_ID` from your current `az account` so Terraform's `azurerm` provider reuses your CLI auth (no service principal needed for single-user deploys).
- Prompts interactively (with `read -s` for secrets) for anything not already in the environment.
- Wires every input through `TF_VAR_*` env vars and runs `terraform init -upgrade` + `terraform apply -auto-approve`.
- Tightens `terraform.tfstate` to mode `0600` (it contains every generated secret in plaintext).
- Kicks off the schema-bootstrap job and polls until success.
- Hits the health endpoint to confirm the API is up.

## What's in state

Terraform generates and persists:

- A **32-char Postgres admin password** ([`random_password.postgres`](main.tf))
- A **32-char registration token** ([`random_password.registration_secret`](main.tf))
- A **resource-group-stable suffix** ([`random_id.suffix`](main.tf)) for the Postgres server's globally-unique DNS name

**Re-applies do NOT rotate any of these** — they're keyed to the resource lifecycle. To rotate, run `terraform taint random_password.<name>` and re-apply.

Read generated values back at any time:

```bash
terraform output -raw api_url
terraform output -raw registration_secret
terraform output -raw postgres_admin_password
```

## File map

| File | Purpose |
| --- | --- |
| [`versions.tf`](versions.tf) | Required terraform/provider versions (`hashicorp/azurerm ~> 4.20`, `hashicorp/random ~> 3.6`) |
| [`variables.tf`](variables.tf) | All inputs (Apple + Reddit + region + image) |
| [`main.tf`](main.tf) | Resource group, random secrets, locals (DB URLs, worker map, shared env/secret bundles) |
| [`logs.tf`](logs.tf) | Log Analytics workspace |
| [`postgres.tf`](postgres.tf) | Postgres Flex Server + PgBouncer config + AllowAllAzureIps firewall + database |
| [`containerenv.tf`](containerenv.tf) | Container Apps environment |
| [`redis.tf`](redis.tf) | `redis:7-alpine` container app with internal TCP ingress |
| [`api.tf`](api.tf) | Public-ingress API container app + Secret-type volume |
| [`scheduler.tf`](scheduler.tf) | Single-replica scheduler container app |
| [`worker.tf`](worker.tf) | Worker container apps (one per queue via `for_each`) |
| [`migration-job.tf`](migration-job.tf) | Container Apps Job — idempotent schema load |
| [`outputs.tf`](outputs.tf) | api_fqdn, health_url, registration_secret, postgres_*, etc. |
| [`deploy.sh`](deploy.sh) | Orchestrator (prompts, exports `TF_VAR_*`, runs terraform, kicks off migration) |
| [`verify.sh`](verify.sh) | Post-deploy: health check + log tail + test-push instructions |
| [`teardown.sh`](teardown.sh) | `terraform destroy` with confirmation prompt |

## Design notes / FAQs

**Why Redis as a container app and not Azure Cache for Redis?**
Saves ~$16/mo vs the cheapest Azure Cache Basic C0. The upstream README explicitly OKs sharing one Redis instance for both queue + locks. On container restart, in-flight queue jobs are lost — but the scheduler republishes work on its next 5s tick, so it's recoverable. If you want persistence, replace [`azurerm_container_app.redis`](redis.tf) with an `azurerm_redis_cache` resource and update `local.redis_queue_url` + `local.redis_locks_url` in [main.tf](main.tf).

**Why Postgres Flex B1ms and not a managed-pool service?**
B1ms has PgBouncer built in on port 6432, which is exactly what apollo-backend's `cmdutil.NewDatabasePool` wants. No separate pooler tier needed. The `DATABASE_CONNECTION_POOL_URL` MUST be query-string-free (pgx appends `?pool_max_conns=...` so a second `?` breaks it) — enforced in [main.tf](main.tf).

**Why not VNet integration?**
The cheaper Consumption Container Apps env doesn't support custom VNets. Workload Profile envs do but add ~$30/mo for the env alone. Since the Postgres firewall rule restricts to Azure-internal IPs and TLS is enforced on every hop, public network access is acceptable for a single-tenant deployment. Swap to a Workload Profile env if you want a private VNet.

**`apple_apns_sandbox = true` — is that right?**
Yes for dev-signed sideloads (the only kind you can do without enterprise distribution). Apollo's release-signed binary sent `sandbox=false` because it was App Store production; your build runs against a dev cert, so the device registers an APNs sandbox token. If `apple_apns_sandbox` is false, you'll get `BadDeviceToken` and the worker silently auto-deletes the device row — a failure mode that looks like the backend just doesn't work.

**`APPLE_KEY_PATH` is `/etc/secrets/apple-key-pem`, not `apple.p8` — why?**
Container Apps `Secret`-type volumes expose every container-app secret as a file named after the secret. The AzureRM provider doesn't (yet) support per-file path remapping on the volume. So the `.p8` lands at `/etc/secrets/apple-key-pem`; we point `APPLE_KEY_PATH` there. apollo-backend reads the file path, not the filename, so this is invisible to the app.

**Re-deploying after a code change?**
Terraform is fully declarative — `terraform apply` (or re-run `./deploy.sh`) diffs in place. Container Apps revisions roll forward automatically.

**Image pinning?**
[`variables.tf`](variables.tf) defaults to `ghcr.io/apollo-reborn/apollo-backend:latest`. Pin a SHA via `TF_VAR_backend_image=ghcr.io/apollo-reborn/apollo-backend:<sha>` once you want reproducibility.

**Schema source pinning?**
`var.schema_source_ref` defaults to the apollo-backend `main` branch. Bump via `TF_VAR_schema_source_ref=<sha>` if you need a specific revision.

**Remote state?**
Default is local state (`./terraform.tfstate`) — gitignored, mode 0600. Add a `backend "azurerm" {}` block in [versions.tf](versions.tf) and bootstrap a storage account if you want team-shared remote state. For single-user deploys, local state is simpler and the file lives next to the `.p8` you already need to protect.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `terraform apply` fails on Postgres with "Server name already exists" | Reusing the same `random_id.suffix` after a partial teardown | `terraform state rm random_id.suffix && terraform apply` or fully destroy + re-deploy |
| `apollo-api` provisions then "Failed" | Image pull permission or env crash on startup | `az containerapp logs show -g apollo-backend-rg -n apollo-api --follow` — look for `panic:` |
| `BadDeviceToken` in worker logs | `apple_apns_sandbox` mismatch | Confirm `apple_apns_sandbox = true` (default); check env on the container app |
| Test push returns 200 but no notification arrives | Topic mismatch | `apple_apns_topic` must EXACTLY match the IPA's bundle ID |
| Health endpoint 503 | Container restarting in a loop | `az containerapp logs show -g apollo-backend-rg -n apollo-api --follow` |
| Migration job stuck "Running" | Postgres not yet reachable; firewall propagation lag | Wait 2 min, retry `az containerapp job start --name apollo-migrate -g apollo-backend-rg` |
| Test Connection in tweak fails | Backend URL typo, or registration token mismatch | Re-copy from `terraform output -raw api_url` and `terraform output -raw registration_secret` |
| `azurerm` provider auth fails | `ARM_SUBSCRIPTION_ID` not set | `export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)` then retry. (deploy.sh does this automatically.) |
| First inbox message never pushes | Worker primed `check_count=1` from cold-start cursor | `UPDATE accounts SET check_count = 1 WHERE username = '<you>';` — see verify.sh |

## Cleanup

```bash
./teardown.sh
```

Or manually:

```bash
terraform destroy
# nuclear option that ignores state:
az group delete --name apollo-backend-rg --yes --no-wait
```

`terraform.tfstate*` survives teardown — delete it manually for a fully clean slate.
