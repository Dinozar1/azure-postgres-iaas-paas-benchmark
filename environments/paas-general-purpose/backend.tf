terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-pgbench"
    storage_account_name = "sttfstatepgbench01"
    container_name       = "tfstate"
    key                  = "paas-general-purpose.tfstate"
  }
}