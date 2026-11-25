terraform {
  required_version = ">= 1.9"

  # Applied once, by a person with Entra ID and Owner rights. Local state by design:
  # this layer creates the remote state store the pipeline layer uses.
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.40"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
  storage_use_azuread = true
}

provider "azuread" {}
