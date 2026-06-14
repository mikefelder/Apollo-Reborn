// apollo-worker-* — one container app per rmq queue. Runs
//   apollo worker --queue <name> --consumers <n>
//
// Consumer counts from local.workers mirror upstream docker-compose.yml.
// One replica per queue is enough at single-tenant scale; if notifications
// queue depth grows, bump max_replicas and add a custom_scale_rule keyed on
// rmq queue depth.

resource "azurerm_container_app" "worker" {
  for_each = local.workers

  name                         = "${var.name_prefix}-worker-${each.key}"
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
      name   = "apollo-worker"
      image  = var.backend_image
      cpu    = 0.5
      memory = "1Gi"
      args = [
        "worker",
        "--queue", each.key,
        "--consumers", tostring(each.value),
      ]

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
