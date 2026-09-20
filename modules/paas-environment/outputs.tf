output "db_fqdn" {
  value = module.db.fqdn
}

output "db_admin_login" {
  value = module.db.administrator_login
}

output "db_name" {
  value = module.db.database_name
}

output "client_vm_public_ip" {
  value = module.client_vm.public_ip_address
}
