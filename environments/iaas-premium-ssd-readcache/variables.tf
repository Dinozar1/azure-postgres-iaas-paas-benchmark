variable "environment_name" {
  description = "Identifier for this environment/configuration, used for naming and tagging."
  type        = string
}

variable "location" {
  description = "Azure region for all resources in this environment."
  type        = string
  default     = "belgiumcentral"
}

variable "admin_source_ip" {
  description = "CIDR allowed to reach the VMs over SSH — your current public IP, e.g. \"1.2.3.4/32\". Check with: curl ifconfig.me"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key content used to log into both VMs (client + database)."
  type        = string
}

variable "data_disk_type" {
  description = "Storage type for the PostgreSQL data disk: \"StandardSSD_LRS\" (E20 at 512 GB) or \"Premium_LRS\" (P20). This is the parameter under test for this environment."
  type        = string
}

variable "postgres_admin_password" {
  description = "Password for the PostgreSQL 'postgres' role on the database VM."
  type        = string
  sensitive   = true
}

variable "data_disk_caching" {
  description = "Host caching mode for the PostgreSQL data disk. \"ReadOnly\" in this environment — the one parameter that differs from iaas-premium-ssd."
  type        = string
}
