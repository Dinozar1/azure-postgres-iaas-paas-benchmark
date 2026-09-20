output "vm_id" {
  value = azurerm_linux_virtual_machine.this.id
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.this.name
}

output "public_ip_address" {
  value = azurerm_public_ip.this.ip_address
}

output "private_ip_address" {
  value = azurerm_network_interface.this.private_ip_address
}