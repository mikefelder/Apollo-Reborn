// Log Analytics workspace — Container Apps log destination.
// Free 5 GB/day ingestion; apollo-backend's logging volume sits well under.

resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.name_prefix}-logs-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}
