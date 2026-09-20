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

variable "subnet_id" {
  description = "ID of the subnet the VM's NIC will be attached to (output of the network module)."
  type        = string
}

variable "vm_size" {
  description = "Azure VM size. Standard_B2s_v2, not the originally planned Standard_D2s_v5 — the Azure for Students subscription blocks Dsv5 (quota=0, non-increasable) and every other D-series size tested (NotAvailableForSubscription). B2s_v2 is the confirmed-available size with matching 2 vCPU / 8 GB spec and Premium Storage support. See CLAUDE.md for the full investigation."
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

variable "os_disk_type" {
  description = "Storage type for the OS disk. Not part of the benchmark, kept cheap by default."
  type        = string
  default     = "StandardSSD_LRS"
}

variable "data_disk_type" {
  description = "Storage type for the PostgreSQL data disk: \"StandardSSD_LRS\" (E10) or \"Premium_LRS\" (P10). This is the parameter under test."
  type        = string
}

variable "data_disk_size_gb" {
  description = "Size of the PostgreSQL data disk in GB."
  type        = number
  default     = 128
}

variable "data_disk_caching" {
  description = "Host caching mode for the data disk. Default \"None\": disabling host caching ensures the measured IOPS/latency reflect the actual disk tier rather than the host cache layer — important for this thesis's core comparison."
  type        = string
  default     = "None"
}

variable "postgresql_version" {
  description = "PostgreSQL major version to install (Ubuntu apt package)."
  type        = string
  default     = "16"
}

variable "postgres_admin_password" {
  description = "Password for the PostgreSQL 'postgres' role. Supply via a gitignored tfvars file — never commit it."
  type        = string
  sensitive   = true
}

variable "allowed_client_address_space" {
  description = "CIDR allowed to connect to PostgreSQL on port 5432 in pg_hba.conf. Defaults to the whole VNet, since the client VM's exact IP isn't known to this module."
  type        = string
  default     = "10.0.0.0/16"
}