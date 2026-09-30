terraform {
  required_version = ">= 1.10.0"

  # Remote state is required: state holds every generated password, the
  # storage key and the Redis password. The values live in
  # backend.hcl (copy backend.hcl.example), kept out of the repo:
  #
  #   terraform init -backend-config=backend.hcl
  #
  # For a local `terraform validate` without Azure access:
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
    # time_sleep: waits for role assignments to propagate.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

# azurerm 4.x requires a subscription ID. It is not hardcoded here: export it
# before any plan or apply, e.g.
#   export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
provider "azurerm" {
  features {
    key_vault {
      # keyvault.tf enables purge protection, a permanent setting. The API
      # refuses purges once it is on, so turning these off keeps
      # `terraform destroy` from erroring on every key and vault it touches.
      purge_soft_deleted_keys_on_destroy = false
      purge_soft_delete_on_destroy       = false
    }
  }
}

# azurerm has no provider-level default_tags block. Tagged resources merge
# network.tf's local.common_tags (Project, ManagedBy, Stack) into their
# own tags, and add Name and Component per resource.
