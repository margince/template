terraform {
  required_version = ">= 1.10.0"

  # Remote state is required: it holds the license. The values live in backend.hcl (copy backend.hcl.example), kept
  # out of the repo:
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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      # A purged vault name is gone for good; keep soft-deleted vaults and
      # secrets recoverable.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
    recovery_service {
      # A VM replacement re-creates the protected item. Keep the old
      # recovery points instead of deleting them.
      vm_backup_stop_protection_and_retain_data_on_destroy = true
    }
  }
}
