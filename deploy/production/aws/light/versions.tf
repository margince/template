terraform {
  required_version = ">= 1.10.0"

  # Remote state is required: it holds the license (secrets.tf). The values
  # come from backend.hcl (copy backend.hcl.example; git-ignored):
  #   terraform init -backend-config=backend.hcl
  # use_lockfile (S3 native locking) is why the CLI floor is 1.10.
  #
  # For a local `terraform validate` or `terraform test` without AWS access:
  #   terraform init -backend=false
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "margince"
      Flavour   = "light"
      ManagedBy = "terraform"
      Stack     = var.name_prefix
    }
  }
}
