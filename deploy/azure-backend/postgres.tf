// Azure Database for PostgreSQL Flexible Server — Burstable B1ms with built-in
// PgBouncer enabled on :6432. ~$13.50/mo all-in.
//
// Public network access is enabled but the AllowAllAzureIps firewall rule
// restricts to Azure-internal traffic. TLS is enforced. Container Apps egress
// IPs from the same region land in that range.

resource "azurerm_postgresql_flexible_server" "main" {
  name                          = local.pg_server_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  version                       = "16"
  sku_name                      = "B_Standard_B1ms"
  storage_mb                    = 32768
  storage_tier                  = "P4"
  auto_grow_enabled             = true
  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = true
  zone                          = "1"

  administrator_login    = local.pg_admin_user
  administrator_password = random_password.postgres.result

  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = false
  }

  lifecycle {
    # Storage auto-grow can bump storage_mb above the initial value; ignore the
    # drift so re-applies don't try to shrink the volume back down (which Azure
    # would reject anyway).
    ignore_changes = [
      zone,
      storage_mb,
    ]
  }
}

// Enable the built-in PgBouncer connection pooler on port 6432, in transaction
// pooling mode. apollo-backend's pgx pool expects transaction mode.
resource "azurerm_postgresql_flexible_server_configuration" "pgbouncer_enabled" {
  name      = "pgbouncer.enabled"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "true"
}

resource "azurerm_postgresql_flexible_server_configuration" "pgbouncer_pool_mode" {
  name      = "pgbouncer.pool_mode"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "transaction"

  depends_on = [azurerm_postgresql_flexible_server_configuration.pgbouncer_enabled]
}

// "Allow all Azure services" rule. Container Apps egress IPs are Azure-public
// and rotate, so a CIDR-pinned rule isn't workable on Consumption envs without
// VNet integration (which requires the much pricier Workload Profile tier).
// Security here comes from password + TLS, not from IP allow-listing.
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure" {
  name             = "AllowAllAzureIps"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_database" "apollo" {
  name      = local.pg_database_name
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}
