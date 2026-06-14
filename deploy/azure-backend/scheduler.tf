// apollo-scheduler — single-replica ticker. No ingress.
//
// Every 5s claims due accounts/subreddits/users from Postgres
// (FOR UPDATE SKIP LOCKED) and publishes IDs onto the rmq queues that the
// worker container apps consume.
//
// MUST be single-instance: the FOR UPDATE SKIP LOCKED protects against
// duplicate work, but the ticker itself shouldn't double-fire.

resource "azurerm_container_app" "scheduler" {
  name                         = "${var.name_prefix}-scheduler"
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"

  dynamic "secret" {
    for_each = local.app_secrets
    content {
      name  = secret.key
      value = secret.value
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "apollo-scheduler"
      image  = var.backend_image
      cpu    = 0.25
      memory = "0.5Gi"
      args   = ["scheduler"]

      dynamic "env" {
        for_each = local.app_env_plain
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      dynamic "env" {
        for_each = local.app_env_secret
        content {
          name        = env.value.name
          secret_name = env.value.secret_name
        }
      }

      volume_mounts {
        name = "app-secrets"
        path = "/etc/secrets"
      }
    }

    volume {
      name         = "app-secrets"
      storage_type = "Secret"
    }
  }

  depends_on = [
    azurerm_container_app.redis,
    azurerm_postgresql_flexible_server_database.apollo,
    azurerm_postgresql_flexible_server_configuration.pgbouncer_pool_mode,
  ]
}
