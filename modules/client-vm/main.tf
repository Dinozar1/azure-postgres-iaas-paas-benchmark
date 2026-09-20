module "vm" {
  source = "../linux-vm"

  resource_group_name = var.resource_group_name
  location            = var.location
  environment_name    = var.environment_name
  name_suffix         = "client"
  subnet_id           = var.subnet_id
  vm_size             = var.vm_size
  admin_username      = var.admin_username
  ssh_public_key      = var.ssh_public_key

  custom_data = file("${path.module}/cloud-init.yaml")
}
