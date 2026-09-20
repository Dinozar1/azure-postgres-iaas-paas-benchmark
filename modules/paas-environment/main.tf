# Moduł paas-environment: spina network + client-vm + paas-postgres w
# kompletne środowisko PaaS. Współdzielony przez environments/paas-burstable
# i environments/paas-general-purpose — różnią się wyłącznie wartością sku_name.
resource "azurerm_resource_group" "this" {
  name     = "rg-${var.environment_name}"
  location = var.location

  tags = {
    project     = "thesis-iaas-paas-postgres"
    environment = var.environment_name
  }
}

module "network" {
  source = "../network"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  environment_name    = var.environment_name
  admin_source_ip     = var.admin_source_ip
}

module "client_vm" {
  source = "../client-vm"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  environment_name    = var.environment_name
  subnet_id           = module.network.subnet_id
  ssh_public_key      = var.ssh_public_key
}

module "db" {
  source = "../paas-postgres"

  resource_group_name    = azurerm_resource_group.this.name
  location               = azurerm_resource_group.this.location
  environment_name       = var.environment_name
  server_name            = var.server_name
  sku_name               = var.sku_name
  administrator_password = var.postgres_admin_password

  # Wires the client VM's public IP straight into the Flexible Server
  # firewall — the whole reason paas-postgres doesn't know about client-vm
  # directly.
  allowed_client_ip_addresses = [module.client_vm.public_ip_address]
}
