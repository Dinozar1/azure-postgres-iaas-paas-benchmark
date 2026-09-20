output "db_fqdn" {
  value = module.db.fqdn
}

output "client_vm_public_ip" {
  value = module.client_vm.public_ip_address
}
