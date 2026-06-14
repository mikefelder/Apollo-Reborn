// Top-level wiring: resource group, name suffix, generated secrets, and the
// shared env/secret block definitions consumed by api.tf, scheduler.tf, and
// worker.tf.

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

// Suffix that pins to the lifetime of the deployment. Persisted in state;
// re-applies do NOT regenerate it. Required for globally-unique Postgres
// server DNS names.
resource "random_id" "suffix" {
  byte_length = 4

  keepers = {
    rg = azurerm_resource_group.main.id
  }
}

// Postgres admin password. Azure PG Flex enforces complexity (must contain
// chars from 3 of 4 classes), so we force at least 2 of upper/lower/numeric.
// Persisted in state — re-applies reuse the same value.
resource "random_password" "postgres" {
  length      = 32
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

// Token the tweak sends as X-Registration-Token. apollo-backend gates the 3
// /v1/device/* registration paths on REGISTRATION_SECRET being unset OR this
// header matching.
resource "random_password" "registration_secret" {
  length      = 32
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

// --- Derived values ----------------------------------------------------------

locals {
  suffix         = random_id.suffix.hex
  pg_server_name = "${var.name_prefix}-pg-${local.suffix}"
  // 'apollo' is reserved by some Postgres providers; 'apolloadmin' is not.
  pg_admin_user    = "apolloadmin"
  pg_database_name = "apollo"
  redis_app_name   = "${var.name_prefix}-redis"

  // PgBouncer endpoint (port 6432) for the long-lived API/worker pgx pools.
  // cmdutil.NewDatabasePool in apollo-backend unconditionally appends
  // ?pool_max_conns=..., so we MUST NOT include a query string here.
  database_connection_pool_url = "postgres://${local.pg_admin_user}:${random_password.postgres.result}@${azurerm_postgresql_flexible_server.main.fqdn}:6432/${local.pg_database_name}"

  // Direct connection (port 5432) for the schema-bootstrap migration job.
  // psql tolerates the ?sslmode=require query string.
  database_direct_url = "postgres://${local.pg_admin_user}:${random_password.postgres.result}@${azurerm_postgresql_flexible_server.main.fqdn}:5432/${local.pg_database_name}?sslmode=require"

  // Redis URLs — single internal container app, two logical databases.
  // Peer container apps in the same env reach this app at the bare hostname.
  redis_queue_url = "redis://${local.redis_app_name}:6379/0"
  redis_locks_url = "redis://${local.redis_app_name}:6379/1"

  // Worker fleet. Consumer counts mirror upstream docker-compose.yml.
  workers = {
    "notifications"       = 64
    "stuck-notifications" = 16
    "subreddits"          = 32
    "trending"            = 16
    "users"               = 16
    "live-activities"     = 16
  }

  // --- Shared container-app secrets ----------------------------------------
  // Used by api, scheduler, and all 6 workers. Mounted both as env vars
  // (secretRef) AND as files in the /etc/secrets volume — the latter is how
  // apollo-backend reads the APNs .p8.
  app_secrets = {
    "apple-key-pem"        = var.apple_key_pem
    "registration-secret"  = random_password.registration_secret.result
    "database-url"         = local.database_connection_pool_url
    "reddit-client-id"     = var.reddit_client_id
    "reddit-client-secret" = var.reddit_client_secret
  }

  // Plain env vars shared across api/scheduler/workers.
  app_env_plain = [
    { name = "ENV", value = "production" },
    { name = "REDIS_QUEUE_URL", value = local.redis_queue_url },
    { name = "REDIS_LOCKS_URL", value = local.redis_locks_url },
    // The Secret-type volume exposes each secret as a file named after the
    // secret. The .p8 ends up at /etc/secrets/apple-key-pem.
    { name = "APPLE_KEY_PATH", value = "/etc/secrets/apple-key-pem" },
    { name = "APPLE_KEY_ID", value = var.apple_key_id },
    { name = "APPLE_TEAM_ID", value = var.apple_team_id },
    { name = "APPLE_APNS_TOPIC", value = var.apple_apns_topic },
    // apollo-backend treats any non-empty value as "use sandbox APNs gateway".
    { name = "APPLE_APNS_SANDBOX", value = var.apple_apns_sandbox ? "true" : "" },
    { name = "REDDIT_REDIRECT_URI", value = var.reddit_redirect_uri },
    { name = "REDDIT_USER_AGENT", value = var.reddit_user_agent },
    { name = "OTEL_TRACES_EXPORTER", value = "none" },
    { name = "OTEL_METRICS_EXPORTER", value = "none" },
  ]

  // Env vars sourced from container-app secrets (use secret_name in azurerm).
  app_env_secret = [
    { name = "DATABASE_CONNECTION_POOL_URL", secret_name = "database-url" },
    { name = "REGISTRATION_SECRET", secret_name = "registration-secret" },
    { name = "REDDIT_CLIENT_ID", secret_name = "reddit-client-id" },
    { name = "REDDIT_CLIENT_SECRET", secret_name = "reddit-client-secret" },
  ]
}
