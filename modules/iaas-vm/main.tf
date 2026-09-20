# Moduł iaas-vm: VM + parametryzowany typ dysku (Standard SSD / Premium SSD)
module "vm" {
  source = "../linux-vm"

  resource_group_name = var.resource_group_name
  location            = var.location
  environment_name    = var.environment_name
  name_suffix         = "db"
  subnet_id           = var.subnet_id
  vm_size             = var.vm_size
  admin_username      = var.admin_username
  ssh_public_key      = var.ssh_public_key
  os_disk_type        = var.os_disk_type

  custom_data = templatefile("${path.module}/cloud-init.tpl", {
    postgresql_version           = var.postgresql_version
    postgres_admin_password      = var.postgres_admin_password
    allowed_client_address_space = var.allowed_client_address_space
  })
}

resource "azurerm_managed_disk" "data" {
  name                 = "disk-${var.environment_name}-pgdata"
  resource_group_name  = var.resource_group_name
  location             = var.location
  storage_account_type = var.data_disk_type
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb

  tags = {
    project     = "thesis-iaas-paas-postgres"
    environment = var.environment_name
  }
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = module.vm.vm_id
  lun                = 0
  caching            = var.data_disk_caching
}