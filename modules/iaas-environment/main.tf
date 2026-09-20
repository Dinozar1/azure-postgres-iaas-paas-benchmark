# Moduł iaas-environment: spina network + client-vm + iaas-vm w kompletne
# środowisko IaaS. Współdzielony przez environments/iaas-standard-ssd i
# environments/iaas-premium-ssd — różnią się wyłącznie wartością data_disk_type.
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

module "db_vm" {
  source = "../iaas-vm"

  resource_group_name     = azurerm_resource_group.this.name
  location                = azurerm_resource_group.this.location
  environment_name        = var.environment_name
  subnet_id               = module.network.subnet_id
  ssh_public_key          = var.ssh_public_key
  data_disk_type          = var.data_disk_type
  postgres_admin_password = var.postgres_admin_password

  # allowed_client_address_space left at module default (10.0.0.0/16) —
  # matches the network module's default VNet range, so the client VM
  # can always reach PostgreSQL without extra wiring.
}
