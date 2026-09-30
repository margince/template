# Variables of the earlier design, which built Margince on the VM. Each is
# declared only so that an old terraform.tfvars entry fails with a clear
# message; Terraform would otherwise ignore it with a warning.

variable "azure_region" {
  description = "Removed: renamed to region."
  type        = any
  default     = null
  validation {
    condition     = var.azure_region == null
    error_message = "azure_region was removed: renamed to region. Delete it from terraform.tfvars."
  }
}

variable "enable_vm_backup" {
  description = "Removed: renamed to enable_backup."
  type        = any
  default     = null
  validation {
    condition     = var.enable_vm_backup == null
    error_message = "enable_vm_backup was removed: renamed to enable_backup. Delete it from terraform.tfvars."
  }
}

variable "enable_bastion_developer" {
  description = "Removed: SSH is open to ssh_allowed_cidrs; Bastion is not created."
  type        = any
  default     = null
  validation {
    condition     = var.enable_bastion_developer == null
    error_message = "enable_bastion_developer was removed: SSH is open to ssh_allowed_cidrs; Bastion is not created. Delete it from terraform.tfvars."
  }
}

variable "operator_ip_allowlist" {
  description = "Removed: use ssh_allowed_cidrs and key_vault_allowed_cidrs."
  type        = any
  default     = null
  validation {
    condition     = var.operator_ip_allowlist == null
    error_message = "operator_ip_allowlist was removed: use ssh_allowed_cidrs and key_vault_allowed_cidrs. Delete it from terraform.tfvars."
  }
}

variable "public_hostname" {
  description = "Removed: renamed to domain, which is required."
  type        = any
  default     = null
  validation {
    condition     = var.public_hostname == null
    error_message = "public_hostname was removed: renamed to domain, which is required. Delete it from terraform.tfvars."
  }
}

variable "dns_label" {
  description = "Removed: the stack serves only domain."
  type        = any
  default     = null
  validation {
    condition     = var.dns_label == null
    error_message = "dns_label was removed: the stack serves only domain. Delete it from terraform.tfvars."
  }
}

variable "acme_email" {
  description = "Removed: Caddy on the server gets the certificate (docs/deploy.md Section 5)."
  type        = any
  default     = null
  validation {
    condition     = var.acme_email == null
    error_message = "acme_email was removed: Caddy on the server gets the certificate (docs/deploy.md Section 5). Delete it from terraform.tfvars."
  }
}

variable "break_glass_cidrs" {
  description = "Removed: nginx is not installed; Caddy routes the traffic (docs/deploy.md Section 5.10)."
  type        = any
  default     = null
  validation {
    condition     = var.break_glass_cidrs == null
    error_message = "break_glass_cidrs was removed: nginx is not installed; Caddy routes the traffic (docs/deploy.md Section 5.10). Delete it from terraform.tfvars."
  }
}

variable "auth_rate_limit_per_minute" {
  description = "Removed: nginx is not installed; Caddy routes the traffic (docs/deploy.md Section 5.10)."
  type        = any
  default     = null
  validation {
    condition     = var.auth_rate_limit_per_minute == null
    error_message = "auth_rate_limit_per_minute was removed: nginx is not installed; Caddy routes the traffic (docs/deploy.md Section 5.10). Delete it from terraform.tfvars."
  }
}

variable "margince_git_url" {
  description = "Removed: the VM does not build Margince; make release builds the images."
  type        = any
  default     = null
  validation {
    condition     = var.margince_git_url == null
    error_message = "margince_git_url was removed: the VM does not build Margince; make release builds the images. Delete it from terraform.tfvars."
  }
}

variable "margince_git_ref" {
  description = "Removed: the VM does not build Margince; make deploy VERSION=<v> selects the release."
  type        = any
  default     = null
  validation {
    condition     = var.margince_git_ref == null
    error_message = "margince_git_ref was removed: the VM does not build Margince; make deploy VERSION=<v> selects the release. Delete it from terraform.tfvars."
  }
}

variable "workspace_name" {
  description = "Removed: set the workspace in deploy/production/config/margince.yaml."
  type        = any
  default     = null
  validation {
    condition     = var.workspace_name == null
    error_message = "workspace_name was removed: set the workspace in deploy/production/config/margince.yaml. Delete it from terraform.tfvars."
  }
}

variable "workspace_base_currency" {
  description = "Removed: set the workspace in deploy/production/config/margince.yaml."
  type        = any
  default     = null
  validation {
    condition     = var.workspace_base_currency == null
    error_message = "workspace_base_currency was removed: set the workspace in deploy/production/config/margince.yaml. Delete it from terraform.tfvars."
  }
}

variable "workspace_base_language" {
  description = "Removed: set the workspace in deploy/production/config/margince.yaml."
  type        = any
  default     = null
  validation {
    condition     = var.workspace_base_language == null
    error_message = "workspace_base_language was removed: set the workspace in deploy/production/config/margince.yaml. Delete it from terraform.tfvars."
  }
}

variable "workspace_timezone" {
  description = "Removed: set the workspace in deploy/production/config/margince.yaml."
  type        = any
  default     = null
  validation {
    condition     = var.workspace_timezone == null
    error_message = "workspace_timezone was removed: set the workspace in deploy/production/config/margince.yaml. Delete it from terraform.tfvars."
  }
}

variable "bootstrap_admin_email" {
  description = "Removed: set bootstrap_admin in deploy/production/config/margince.yaml."
  type        = any
  default     = null
  validation {
    condition     = var.bootstrap_admin_email == null
    error_message = "bootstrap_admin_email was removed: set bootstrap_admin in deploy/production/config/margince.yaml. Delete it from terraform.tfvars."
  }
}

variable "bootstrap_admin_display_name" {
  description = "Removed: set bootstrap_admin in deploy/production/config/margince.yaml."
  type        = any
  default     = null
  validation {
    condition     = var.bootstrap_admin_display_name == null
    error_message = "bootstrap_admin_display_name was removed: set bootstrap_admin in deploy/production/config/margince.yaml. Delete it from terraform.tfvars."
  }
}

variable "include_bootstrap_admin" {
  description = "Removed: the host adapter generates the first admin password (make host-admin-password)."
  type        = any
  default     = null
  validation {
    condition     = var.include_bootstrap_admin == null
    error_message = "include_bootstrap_admin was removed: the host adapter generates the first admin password (make host-admin-password). Delete it from terraform.tfvars."
  }
}

variable "environment_posture" {
  description = "Removed: list MARGINCE_ENV in deploy/production/secrets for a test environment (docs/deploy.md Section 5.8)."
  type        = any
  default     = null
  validation {
    condition     = var.environment_posture == null
    error_message = "environment_posture was removed: list MARGINCE_ENV in deploy/production/secrets for a test environment (docs/deploy.md Section 5.8). Delete it from terraform.tfvars."
  }
}

variable "db_sku_name" {
  description = "Removed: Postgres runs as a container on the VM; no managed database is created."
  type        = any
  default     = null
  validation {
    condition     = var.db_sku_name == null
    error_message = "db_sku_name was removed: Postgres runs as a container on the VM; no managed database is created. Delete it from terraform.tfvars."
  }
}

variable "db_version" {
  description = "Removed: Postgres runs as a container on the VM; no managed database is created."
  type        = any
  default     = null
  validation {
    condition     = var.db_version == null
    error_message = "db_version was removed: Postgres runs as a container on the VM; no managed database is created. Delete it from terraform.tfvars."
  }
}

variable "db_storage_mb" {
  description = "Removed: Postgres runs as a container on the VM; its data is on the data disk."
  type        = any
  default     = null
  validation {
    condition     = var.db_storage_mb == null
    error_message = "db_storage_mb was removed: Postgres runs as a container on the VM; its data is on the data disk. Delete it from terraform.tfvars."
  }
}

variable "db_backup_retention_days" {
  description = "Removed: Postgres runs as a container on the VM; enable_backup covers the data disk."
  type        = any
  default     = null
  validation {
    condition     = var.db_backup_retention_days == null
    error_message = "db_backup_retention_days was removed: Postgres runs as a container on the VM; enable_backup covers the data disk. Delete it from terraform.tfvars."
  }
}
