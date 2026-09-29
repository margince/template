terraform {
  required_version = ">= 1.10.0"

  # Remote state is required: state holds every generated credential from
  # secrets.tf in plain text, so it must live in a protected S3 bucket that
  # only deployment identities can reach, never on a laptop. The values come
  # from backend.hcl (copy backend.hcl.example; git-ignored):
  #   terraform init -backend-config=backend.hcl
  # use_lockfile (S3 native locking) is why the CLI floor is 1.10.
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "margince"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
