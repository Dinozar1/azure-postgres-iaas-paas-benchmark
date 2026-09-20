# Moduł iaas-vm: VM + parametryzowany typ dysku (Standard SSD / Premium SSD)
resource "azurerm_public_ip" "this" {
  name                = "pip-${var.environment_name}-db"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    project     = "thesis-iaas-paas-postgres"
    environment = var.environment_name
  }
}

resource "azurerm_network_interface" "this" {
  name                = "nic-${var.environment_name}-db"
  resource_group_name = var.resource_group_name
  location            = var.location

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this.id
  }

  tags = {
    project     = "thesis-iaas-paas-postgres"
    environment = var.environment_name
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  name                = "vm-${var.environment_name}-db"
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = var.vm_size
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.this.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  disable_password_authentication = true

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  boot_diagnostics {
    storage_account_uri = null # uses Azure Managed Boot Diagnostics
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.tpl", {
    postgresql_version           = var.postgresql_version
    postgres_admin_password      = var.postgres_admin_password
    allowed_client_address_space = var.allowed_client_address_space
  }))

  tags = {
    project     = "thesis-iaas-paas-postgres"
    environment = var.environment_name
  }
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
  virtual_machine_id = azurerm_linux_virtual_machine.this.id
  lun                 = 0
  caching             = var.data_disk_caching
}