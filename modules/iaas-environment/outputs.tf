output "db_vm_public_ip" {
  value = module.db_vm.public_ip_address
}

# Azure Monitor resource for the run-time metrics scripts/collect-results.sh
# pulls (CPU, CPU credits, data-disk burst credits). Disk burst credits are
# reported against the VM, not the disk, so the VM id is all that is needed.
output "metrics_resource_id" {
  value = module.db_vm.vm_id
}

output "db_vm_private_ip" {
  value = module.db_vm.private_ip_address
}

output "client_vm_public_ip" {
  value = module.client_vm.public_ip_address
}
