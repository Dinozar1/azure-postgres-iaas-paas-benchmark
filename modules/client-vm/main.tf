resource "azurerm_public_ip" "this" {
  name                = "pip-${var.environment_name}-client"
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
  name                = "nic-${var.environment_name}-client"
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
  name                = "vm-${var.environment_name}-client"
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
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(file("${path.module}/cloud-init.yaml"))

  tags = {
    project     = "thesis-iaas-paas-postgres"
    environment = var.environment_name
  }
}