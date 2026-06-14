// Container Apps managed environment — Consumption profile (scale-to-zero
// capable, per-second billing). TCP ingress (used by apollo-redis for
// inter-service traffic) is supported on Consumption.

resource "azurerm_container_app_environment" "main" {
  name                       = "${var.name_prefix}-env-${local.suffix}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
}
