// apollo-api — public HTTPS ingress (target port 4000 inside the container,
// terminated at the Container Apps managed ingress on 443).
//
// This is the only container app the tweak talks to. Its FQDN is what you
// paste into Settings → Custom API → Notification Backend → URL.

resource "azurerm_container_app" "api" {
  name                         = "${var.name_prefix}-api"
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"

  ingress {
    external_enabled           = true
    target_port                = 4000
    transport                  = "auto"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  dynamic "secret" {
    for_each = local.app_secrets
    content {
      name  = secret.key
      value = secret.value
    }
  }

  template {
    min_replicas = 1
    max_replicas = 3

    container {
      name   = "apollo-api"
      image  = var.backend_image
      cpu    = 0.5
      memory = "1Gi"
      args   = ["api"]

      env {
        name  = "PORT"
        value = "4000"
      }

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

      // Mounts every container-app secret as a file in /etc/secrets/<name>.
      // The .p8 ends up at /etc/secrets/apple-key-pem (APPLE_KEY_PATH points
      // there). Other secrets become harmless extra files.
      volume_mounts {
        name = "app-secrets"
        path = "/etc/secrets"
      }

      liveness_probe {
        transport               = "HTTP"
        path                    = "/v1/health"
        port                    = 4000
        initial_delay           = 15
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 5
      }

      readiness_probe {
        transport               = "HTTP"
        path                    = "/v1/health"
        port                    = 4000
        interval_seconds        = 10
        timeout                 = 3
        failure_count_threshold = 3
      }
    }

    volume {
      name         = "app-secrets"
      storage_type = "Secret"
    }

    http_scale_rule {
      name                = "http-scale"
      concurrent_requests = 100
    }
  }

  depends_on = [
    azurerm_container_app.redis,
    azurerm_postgresql_flexible_server_database.apollo,
    azurerm_postgresql_flexible_server_configuration.pgbouncer_pool_mode,
  ]
}
