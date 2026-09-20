resource "azurerm_postgresql_flexible_server" "this" {
  name                   = var.server_name
  resource_group_name    = var.resource_group_name
  location               = var.location
  version                = var.postgresql_version
  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password

  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = var.geo_redundant_backup_enabled

  public_network_access_enabled = true

  tags = {
    project     = "thesis-iaas-paas-postgres"
    environment = var.environment_name
  }

  lifecycle {
    ignore_changes = [zone] # Azure may auto-assign/rebalance the zone; avoid noisy diffs
  }
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allowed_clients" {
  for_each = { for idx, ip in var.allowed_client_ip_addresses : idx => ip }

  name             = "allow-client-${each.key}"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = each.value
  end_ip_address   = each.value
}

resource "azurerm_postgresql_flexible_server_database" "pgbench" {
  name      = "pgbench_db"
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}