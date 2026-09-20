output "db_vm_public_ip" {
  value = module.db_vm.public_ip_address
}

output "db_vm_private_ip" {
  value = module.db_vm.private_ip_address
}

output "client_vm_public_ip" {
  value = module.client_vm.public_ip_address
}
