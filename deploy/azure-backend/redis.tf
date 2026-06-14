// Redis as a Container App — internal TCP ingress on :6379.
//
// The apollo-backend README explicitly OKs sharing one Redis instance for
// both rmq queues (REDIS_QUEUE_URL → DB 0) and the dedup-locks Lua script
// (REDIS_LOCKS_URL → DB 1). Vanilla redis:7-alpine with no persistence.
//
// On restart, in-flight queue jobs and short-lived dedup locks are lost. Both
// are recoverable: the scheduler republishes work on its next 5s tick, and
// the dedup locks are short-TTL by design. If you want persistence, swap this
// for an azurerm_redis_cache resource (Basic C0 ≈ $16/mo) and update
// local.redis_queue_url / local.redis_locks_url accordingly.
//
// Peer apps in the same env reach this app at the bare hostname.

resource "azurerm_container_app" "redis" {
  name                         = local.redis_app_name
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"

  ingress {
    external_enabled = false
    target_port      = 6379
    exposed_port     = 6379
    transport        = "tcp"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "redis"
      image  = "redis:7-alpine"
      cpu    = 0.25
      memory = "0.5Gi"

      command = ["redis-server"]
      args = [
        "--maxmemory-policy", "noeviction",
        "--save", "",
        "--appendonly", "no",
      ]

      liveness_probe {
        transport        = "TCP"
        port             = 6379
        initial_delay    = 10
        interval_seconds = 30
      }
    }
  }
}
