terraform {
  required_version = ">= 1.1.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.80.0"

    }
  }

  backend "azurerm" {
    resource_group_name   = "NewResourceGroup"
    storage_account_name  = "storageaccounttask2"
    container_name        = "tfstate"
    key                   = "terraform.tfstate"
  }
}



provider "azurerm" {
  features {}
  subscription_id = "******************8"
  skip_provider_registration = true
}
