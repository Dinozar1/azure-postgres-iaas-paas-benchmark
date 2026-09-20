output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "subnet_id" {
  value = azurerm_subnet.compute.id
}

output "subnet_name" {
  value = azurerm_subnet.compute.name
}

output "nsg_id" {
  value = azurerm_network_security_group.compute.id
}