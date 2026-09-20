variable "resource_group_name" {
  description = "Name of the resource group where the Flexible Server will be created."
  type        = string
}

variable "location" {
  description = "Azure region for the Flexible Server."
  type        = string
}

variable "environment_name" {
  description = "Short identifier of the environment (e.g. \"paas-burstable\"), used for tagging."
  type        = string
}

variable "server_name" {
  description = "Globally unique server name (forms <name>.postgres.database.azure.com). Adjust if it's already taken."
  type        = string
  default     = "psql-thesis-pgbench"
}

variable "sku_name" {
  description = <<-EOT
    Compute SKU for the Flexible Server, e.g. "B_Standard_B1ms" (Burstable)
    or "GP_Standard_D2s_v3" (General Purpose). Verify the exact SKUs
    available in your region before applying:
    az postgres flexible-server list-skus --location <region>
  EOT
  type        = string
}

variable "storage_mb" {
  description = "Provisioned storage in MB. Defaults to 131072 (128 GB) to match the IaaS data disk size for a fair comparison."
  type        = number
  default     = 131072
}

variable "postgresql_version" {
  description = "PostgreSQL major version. Kept in sync with the IaaS module's version."
  type        = string
  default     = "16"
}

variable "administrator_login" {
  description = "Administrator username (cannot be \"postgres\" — reserved by the managed service)."
  type        = string
  default     = "pgbenchadmin"
}

variable "administrator_password" {
  description = "Administrator password. Supply via a gitignored tfvars file — never commit it."
  type        = string
  sensitive   = true
}

variable "backup_retention_days" {
  description = "Backup retention in days. 7 is the service minimum and keeps backup storage cost negligible for a short-lived benchmark environment."
  type        = number
  default     = 7
}

variable "geo_redundant_backup_enabled" {
  description = "Whether backups are geo-redundant. Left off to keep cost minimal — irrelevant for an ephemeral benchmark environment."
  type        = bool
  default     = false
}

variable "allowed_client_ip_addresses" {
  description = "Public IP addresses allowed through the server firewall (typically just the client VM's public IP, wired in from the environment)."
  type        = list(string)
}