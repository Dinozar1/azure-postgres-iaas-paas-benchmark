terraform {
  required_version = ">= 1.7"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

provider "azurerm" {
  features {}

  # See bootstrap/main.tf for why: providers are already registered manually.
  skip_provider_registration = true
}

module "environment" {
  source = "../../modules/iaas-environment"

  environment_name        = var.environment_name
  location                = var.location
  admin_source_ip         = var.admin_source_ip
  ssh_public_key          = var.ssh_public_key
  data_disk_type          = var.data_disk_type
  postgres_admin_password = var.postgres_admin_password
}
