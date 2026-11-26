terraform {
  required_version = ">= 1.9"

  # Remote state created by infra/bootstrap. Values passed with -backend-config
  # (see pipelines/templates/terraform.yml). Entra ID auth only, no storage keys.
  backend "azurerm" {
    use_azuread_auth = true
    key              = "policy-assistant.tfstate"
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.40"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.5"
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
    cognitive_account {
      purge_soft_delete_on_destroy = true
    }
  }
  # The pipeline identity is only allowed into one resource group, so it
  # cannot register resource providers at subscription level.
  resource_provider_registrations = "none"
}

provider "azapi" {}
