// Schema-bootstrap job — runs once after first deploy via
//   az containerapp job start --name apollo-migrate -g <rg> --no-wait
// then poll execution status with `az containerapp job execution show`.
//
// Reproduces upstream's docker/migrate.sh: idempotent load of docs/schema.sql
// plus the live_activities patch. Pulled at runtime from raw.githubusercontent
// so we don't have to build a custom image.
//
// alpine + apk-installed psql; lightweight and starts in ~5s.

locals {
  schema_url = "https://raw.githubusercontent.com/Apollo-Reborn/apollo-backend/${var.schema_source_ref}/docs/schema.sql"
  patch_url  = "https://raw.githubusercontent.com/Apollo-Reborn/apollo-backend/${var.schema_source_ref}/migrations/000013_restore_live_activities.up.sql"

  // Two-step idempotent migration. Embedded as a single heredoc so the
  // Container Apps Job needs no custom image.
  // $SCHEMA_URL/$DATABASE_URL etc. are shell vars (Terraform doesn't try to
  // interpolate them — only ${...} is consumed by HCL).
  migrate_script = <<-EOT
    set -eu
    apk add --no-cache postgresql-client curl >/dev/null

    curl -fsSL "$SCHEMA_URL" -o /tmp/schema.sql
    curl -fsSL "$PATCH_URL"  -o /tmp/patch.sql

    # Idempotent: only load schema.sql if the accounts table is absent.
    if psql "$DATABASE_URL" -tAc "SELECT to_regclass('public.accounts')" | grep -q accounts; then
      echo "schema already loaded, skipping"
    else
      psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f /tmp/schema.sql
      echo "schema loaded"
    fi

    # Idempotent: only apply the live_activities patch if its table is absent.
    if psql "$DATABASE_URL" -tAc "SELECT to_regclass('public.live_activities')" | grep -q live_activities; then
      echo "live_activities present, skipping patch"
    else
      psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f /tmp/patch.sql
      echo "live_activities patch applied"
    fi
  EOT
}

resource "azurerm_container_app_job" "migrate" {
  name                         = "${var.name_prefix}-migrate"
  resource_group_name          = azurerm_resource_group.main.name
  location                     = azurerm_resource_group.main.location
  container_app_environment_id = azurerm_container_app_environment.main.id

  replica_timeout_in_seconds = 600
  replica_retry_limit        = 0

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  secret {
    name  = "database-url"
    value = local.database_direct_url
  }

  template {
    container {
      name    = "migrate"
      image   = "alpine:3.19"
      cpu     = 0.25
      memory  = "0.5Gi"
      command = ["/bin/sh", "-c"]
      args    = [local.migrate_script]

      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }
      env {
        name  = "SCHEMA_URL"
        value = local.schema_url
      }
      env {
        name  = "PATCH_URL"
        value = local.patch_url
      }
    }
  }

  depends_on = [
    azurerm_postgresql_flexible_server_database.apollo,
    azurerm_postgresql_flexible_server_configuration.pgbouncer_pool_mode,
    azurerm_postgresql_flexible_server_firewall_rule.allow_azure,
  ]
}
