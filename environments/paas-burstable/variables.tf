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
  description = "CIDR allowed to reach the client VM over SSH — your current public IP, e.g. \"1.2.3.4/32\". Check with: curl ifconfig.me"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key content used to log into the client VM."
  type        = string
}

variable "server_name" {
  description = "Globally unique Flexible Server name."
  type        = string
}

variable "sku_name" {
  description = <<-EOT
    Compute SKU for the Flexible Server. This is the parameter under test
    for this environment. Verify exact names available in Poland Central
    first: az postgres flexible-server list-skus --location belgiumcentral
  EOT
  type        = string
}

variable "postgres_admin_password" {
  description = "Password for the Flexible Server administrator login."
  type        = string
  sensitive   = true
}