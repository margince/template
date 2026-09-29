terraform {
  required_version = ">= 1.7.0"

  # Remote state is required: it holds every generated password and the Entra
  # client secret. The values live in backend.hcl (copy backend.hcl.example),
  # kept out of the repo:
  #
  #   terraform init -backend-config=backend.hcl
  #
  # For a local `terraform validate` or `terraform test` without Azure access:
  #   terraform init -backend=false
  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      # A POC should tear down cleanly, but a purged vault name is gone for
      # good; keep soft-deleted vaults and secrets recoverable.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

# Authenticates as whoever runs `terraform apply` (az login). With
# create_entra_app = true that identity needs Entra's Application
# Administrator (or Cloud Application Administrator) role.
provider "azuread" {}
