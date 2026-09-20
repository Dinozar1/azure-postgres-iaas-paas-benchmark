variable "resource_group_name" {
  description = "Name of the resource group where the client VM will be created."
  type        = string
}

variable "location" {
  description = "Azure region for the client VM."
  type        = string
}

variable "environment_name" {
  description = "Short identifier of the environment (e.g. \"iaas-premium-ssd\"), used for tagging and naming."
  type        = string
}

variable "subnet_id" {
  description = "ID of the subnet the client VM's NIC will be attached to (output of the network module)."
  type        = string
}

variable "vm_size" {
  description = "Azure VM size for the pgbench client. Standard_B2s_v2 — confirmed available on this Azure for Students subscription (see modules/iaas-vm for the full investigation); kept identical to the database VM size for consistency, though this VM's own power matters less since it only runs pgbench."
  type        = string
  default     = "Standard_B2s_v2"
}

variable "admin_username" {
  description = "Administrator username for SSH login."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "SSH public key content used for authentication (password auth is disabled)."
  type        = string
}