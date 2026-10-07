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
  description = "Storage type for the PostgreSQL data disk: \"StandardSSD_LRS\" (E20 at the default size) or \"Premium_LRS\" (P20). This is the parameter under test."
  type        = string
}

variable "data_disk_size_gb" {
  description = <<-EOT
    Size of the PostgreSQL data disk in GB. Must stay identical across both IaaS
    variants — only data_disk_type differs, so size is a controlled variable.

    512 GB, not 128 GB: Azure provisions IOPS by size tier, and at 128 GB both
    tiers land on the same 500 IOPS (E10 and P10 are indistinguishable in
    provisioned throughput), which would leave the disk-layer comparison with
    nothing to measure. Measured on this subscription:

      size    StandardSSD    Premium      ratio
      128 GB  500 / 100MBps  500 / 100    1.0x
      256 GB  500 / 100MBps  1100 / 125   2.2x
      512 GB  500 / 100MBps  2300 / 150   4.6x
      1024 GB 500 / 100MBps  5000 / 200   (over the VM cap)

    512 GB is the largest size whose Premium tier (2300 IOPS) still fits under
    the Standard_B2s_v2 uncached ceiling of 3750 IOPS, so the VM never masks the
    disk difference. At 1024 GB the VM, not the disk, would become the limit.
  EOT
  type        = number
  default     = 512
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

variable "postgresql_settings" {
  description = <<-EOT
    postgresql.conf settings applied with pg_conftool before PostgreSQL first
    starts. The defaults carry over every performance-relevant setting Azure
    applies to the PaaS reference server — GP_Standard_D2s_v3, the same
    2 vCPU / 8 GiB as Standard_B2s_v2 — read from its pg_settings, so both arms
    run the same engine configuration and the comparison isolates the
    deployment model. Azure-specific settings, logging, certificates,
    extensions and the PaaS WAL archiving are deliberately not carried over;
    CLAUDE.md has the full parameter table with the reason for each.
  EOT
  type        = map(string)
  default = {
    # Memory
    shared_buffers       = "2GB"
    effective_cache_size = "6GB"
    maintenance_work_mem = "216064kB"
    # WAL and checkpoints
    wal_buffers        = "16MB"
    wal_compression    = "pglz"
    max_wal_size       = "25600MB"
    checkpoint_timeout = "600s"
    # Background writing and write-back
    bgwriter_delay      = "20ms"
    backend_flush_after = "2MB"
    # Autovacuum
    vacuum_cost_page_miss = "10"
    # Planner and execution
    random_page_cost          = "2"
    jit                       = "off"
    default_toast_compression = "lz4"
    # Measurement, not tuning: I/O times in pg_stat_io / pg_stat_database.
    # modules/paas-postgres sets the same on the Flexible Server.
    track_io_timing = "on"
  }

  validation {
    condition = alltrue([
      for name, value in var.postgresql_settings :
      can(regex("^[a-z_]+$", name)) && can(regex("^[A-Za-z0-9._]+$", value))
    ])
    error_message = "Setting names must be lowercase identifiers and values plain alphanumerics: cloud-init pastes both into shell commands unquoted."
  }
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