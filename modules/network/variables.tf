variable "resource_group_name" {
  description = "Name of the resource group where network resources will be created."
  type        = string
}

variable "location" {
  description = "Azure region for the network resources."
  type        = string
}

variable "environment_name" {
  description = "Short identifier of the environment (e.g. \"iaas-premium-ssd\"), used for tagging."
  type        = string
}

variable "vnet_name" {
  description = "Name of the virtual network."
  type        = string
  default     = "vnet-pgbench"
}

variable "vnet_address_space" {
  description = "Address space of the virtual network."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "subnet_name" {
  description = "Name of the subnet hosting VM-based resources (database VM and/or client VM)."
  type        = string
  default     = "snet-compute"
}

variable "subnet_address_prefixes" {
  description = "Address prefixes of the compute subnet."
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

variable "nsg_name" {
  description = "Name of the network security group attached to the compute subnet."
  type        = string
  default     = "nsg-compute"
}

variable "admin_source_ip" {
  description = "CIDR (e.g. \"1.2.3.4/32\") allowed to reach VMs over SSH. Set this to your current public IP."
  type        = string
}