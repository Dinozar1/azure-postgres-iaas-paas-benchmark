# Moduł linux-vm: bazowy budulec (public IP + NIC + VM) współdzielony przez
# iaas-vm (serwer bazy danych) i client-vm (maszyna z pgbench).
locals {
  common_tags = {
    project     = "thesis-iaas-paas-postgres"
    environment = var.environment_name
  }
}

resource "azurerm_public_ip" "this" {
  name                = "pip-${var.environment_name}-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = local.common_tags
}

resource "azurerm_network_interface" "this" {
  name                = "nic-${var.environment_name}-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this.id
  }

  tags = local.common_tags
}

resource "azurerm_linux_virtual_machine" "this" {
  name                = "vm-${var.environment_name}-${var.name_suffix}"
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

  # Ubuntu 24.04 (noble), not 22.04: noble ships PostgreSQL 16 in its own
  # repositories, matching the version the PaaS Flexible Server runs. On 22.04
  # (PostgreSQL 14) the IaaS arm would either need the external PGDG repo at
  # boot or run a different major version than the PaaS arm.
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  boot_diagnostics {
    storage_account_uri = null # uses Azure Managed Boot Diagnostics
  }

  custom_data = base64encode(var.custom_data)

  tags = local.common_tags
}
