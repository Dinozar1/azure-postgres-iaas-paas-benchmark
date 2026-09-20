variable "resource_group_name" {
  description = "Name of the resource group where the VM will be created."
  type        = string
}

variable "location" {
  description = "Azure region for the VM."
  type        = string
}

variable "environment_name" {
  description = "Short identifier of the environment (e.g. \"iaas-premium-ssd\"), used for tagging and naming."
  type        = string
}

variable "name_suffix" {
  description = "Short role suffix appended to resource names, e.g. \"db\" or \"client\"."
  type        = string
}

variable "subnet_id" {
  description = "ID of the subnet the VM's NIC will be attached to (output of the network module)."
  type        = string
}

variable "vm_size" {
  description = "Azure VM size."
  type        = string
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

variable "os_disk_type" {
  description = "Storage type for the OS disk."
  type        = string
  default     = "StandardSSD_LRS"
}

variable "custom_data" {
  description = "Raw cloud-init content for this VM (base64-encoded internally before being passed to Azure)."
  type        = string
}
