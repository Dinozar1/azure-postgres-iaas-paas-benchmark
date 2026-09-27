output "db_fqdn" {
  value = module.db.fqdn
}

output "db_admin_login" {
  value = module.db.administrator_login
}

output "db_name" {
  value = module.db.database_name
}

# Azure Monitor resource for the run-time metrics scripts/collect-results.sh
# pulls. The Flexible Server publishes its own metric set, unrelated to the
# VM-level ones used on the IaaS side.
output "metrics_resource_id" {
  value = module.db.server_id
}

output "client_vm_public_ip" {
  value = module.client_vm.public_ip_address
}
