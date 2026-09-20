terraform {
  required_version = ">= 1.7"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }

  # Intentionally: local backend. This module creates the storage that
  # every other module's state lives in — it cannot bootstrap itself.
}

provider "azurerm" {
  features {}

  # Skip Terraform's automatic check/registration of the full list of Azure
  # resource providers on every run — we've already registered exactly the
  # ones this project needs (see CLAUDE.md), and on this restricted student
  # subscription the blanket check is slow and prone to transient failures
  # (DNS timeouts, providers we don't use that may not even be registrable).
  skip_provider_registration = true
}

variable "location" {
  description = "Azure region for the resources."
  type        = string
  default     = "belgiumcentral"
}

variable "resource_group_name" {
  description = "Resource group name for the Terraform state backend."
  type        = string
  default     = "rg-tfstate-pgbench"
}

variable "storage_account_name" {
  description = "Storage account name (must be globally unique across Azure: 3-24 chars, lowercase letters/digits)."
  type        = string
  default     = "sttfstatepgbench01"
}

variable "container_name" {
  description = "Name of the container holding the Terraform state files."
  type        = string
  default     = "tfstate"
}

resource "azurerm_resource_group" "tfstate" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    project = "thesis-iaas-paas-postgres"
    purpose = "terraform-remote-state"
  }
}

resource "azurerm_storage_account" "tfstate" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = azurerm_resource_group.tfstate.location
  account_tier             = "Standard"
  account_replication_type = "LRS" # cheapest replication option, sufficient for a state file

  blob_properties {
    versioning_enabled = true # safety net: this is the single copy of state, worth versioning
  }

  tags = {
    project = "thesis-iaas-paas-postgres"
    purpose = "terraform-remote-state"
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = var.container_name
  storage_account_name  = azurerm_storage_account.tfstate.name
  container_access_type = "private"
}

output "resource_group_name" {
  value = azurerm_resource_group.tfstate.name
}

output "storage_account_name" {
  value = azurerm_storage_account.tfstate.name
}

output "container_name" {
  value = azurerm_storage_container.tfstate.name
}

output "backend_config_snippet" {
  description = "Paste these values into backend.tf of each environment under environments/."
  value       = <<-EOT
    resource_group_name  = "${azurerm_resource_group.tfstate.name}"
    storage_account_name = "${azurerm_storage_account.tfstate.name}"
    container_name        = "${azurerm_storage_container.tfstate.name}"
  EOT
}