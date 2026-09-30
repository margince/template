# Variables of the earlier design, which built Margince on the instances. Each is
# declared only so that an old terraform.tfvars entry fails with a clear
# message; Terraform would otherwise ignore it with a warning.

variable "aws_region" {
  description = "Removed: renamed to region."
  type        = any
  default     = null
  validation {
    condition     = var.aws_region == null
    error_message = "aws_region was removed: renamed to region. Delete it from terraform.tfvars."
  }
}

variable "public_base_url" {
  description = "Removed: renamed to domain (the host name only), which is required."
  type        = any
  default     = null
  validation {
    condition     = var.public_base_url == null
    error_message = "public_base_url was removed: renamed to domain (the host name only), which is required. Delete it from terraform.tfvars."
  }
}

variable "image_tag" {
  description = "Removed: the instance does not build Margince; make deploy VERSION=<v> selects the release."
  type        = any
  default     = null
  validation {
    condition     = var.image_tag == null
    error_message = "image_tag was removed: the instance does not build Margince; make deploy VERSION=<v> selects the release. Delete it from terraform.tfvars."
  }
}

variable "admin_bootstrap_password" {
  description = "Removed: the host adapter generates the first admin password (make host-admin-password)."
  type        = any
  default     = null
  validation {
    condition     = var.admin_bootstrap_password == null
    error_message = "admin_bootstrap_password was removed: the host adapter generates the first admin password (make host-admin-password). Delete it from terraform.tfvars."
  }
}

variable "margince_source_dir" {
  description = "Removed: the instance does not build Margince; make release builds the images."
  type        = any
  default     = null
  validation {
    condition     = var.margince_source_dir == null
    error_message = "margince_source_dir was removed: the instance does not build Margince; make release builds the images. Delete it from terraform.tfvars."
  }
}

variable "root_volume_gb" {
  description = "Removed: renamed to os_disk_gb."
  type        = any
  default     = null
  validation {
    condition     = var.root_volume_gb == null
    error_message = "root_volume_gb was removed: renamed to os_disk_gb. Delete it from terraform.tfvars."
  }
}

variable "az_count" {
  description = "Removed: there is no database subnet group; the stack uses one subnet."
  type        = any
  default     = null
  validation {
    condition     = var.az_count == null
    error_message = "az_count was removed: there is no database subnet group; the stack uses one subnet. Delete it from terraform.tfvars."
  }
}

variable "db_instance_class" {
  description = "Removed: Postgres runs as a container on the instance; no RDS instance is created."
  type        = any
  default     = null
  validation {
    condition     = var.db_instance_class == null
    error_message = "db_instance_class was removed: Postgres runs as a container on the instance; no RDS instance is created. Delete it from terraform.tfvars."
  }
}

variable "db_allocated_storage_gb" {
  description = "Removed: Postgres runs as a container on the instance; its data is on the data volume."
  type        = any
  default     = null
  validation {
    condition     = var.db_allocated_storage_gb == null
    error_message = "db_allocated_storage_gb was removed: Postgres runs as a container on the instance; its data is on the data volume. Delete it from terraform.tfvars."
  }
}

variable "db_engine_version" {
  description = "Removed: Postgres runs as a container on the instance; no RDS instance is created."
  type        = any
  default     = null
  validation {
    condition     = var.db_engine_version == null
    error_message = "db_engine_version was removed: Postgres runs as a container on the instance; no RDS instance is created. Delete it from terraform.tfvars."
  }
}

variable "db_backup_retention_days" {
  description = "Removed: Postgres runs as a container on the instance; enable_backup covers the data volume."
  type        = any
  default     = null
  validation {
    condition     = var.db_backup_retention_days == null
    error_message = "db_backup_retention_days was removed: Postgres runs as a container on the instance; enable_backup covers the data volume. Delete it from terraform.tfvars."
  }
}

variable "db_deletion_protection" {
  description = "Removed: Postgres runs as a container on the instance; the data volume has prevent_destroy."
  type        = any
  default     = null
  validation {
    condition     = var.db_deletion_protection == null
    error_message = "db_deletion_protection was removed: Postgres runs as a container on the instance; the data volume has prevent_destroy. Delete it from terraform.tfvars."
  }
}

variable "db_max_connections_alarm_threshold" {
  description = "Removed: there is no RDS instance to alarm on."
  type        = any
  default     = null
  validation {
    condition     = var.db_max_connections_alarm_threshold == null
    error_message = "db_max_connections_alarm_threshold was removed: there is no RDS instance to alarm on. Delete it from terraform.tfvars."
  }
}

variable "redis_image" {
  description = "Removed: Redis runs as the host adapter's container (docs/deploy.md Section 5)."
  type        = any
  default     = null
  validation {
    condition     = var.redis_image == null
    error_message = "redis_image was removed: Redis runs as the host adapter's container (docs/deploy.md Section 5). Delete it from terraform.tfvars."
  }
}

variable "log_retention_days" {
  description = "Removed: no CloudWatch log group is created; logs stay in Docker on the instance."
  type        = any
  default     = null
  validation {
    condition     = var.log_retention_days == null
    error_message = "log_retention_days was removed: no CloudWatch log group is created; logs stay in Docker on the instance. Delete it from terraform.tfvars."
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

variable "enable_waf" {
  description = "Removed: light has no WAF and no CloudFront."
  type        = any
  default     = null
  validation {
    condition     = var.enable_waf == null
    error_message = "enable_waf was removed: light has no WAF and no CloudFront. Delete it from terraform.tfvars."
  }
}

variable "enable_deep_monitoring" {
  description = "Removed: renamed to enable_alarms (default true)."
  type        = any
  default     = null
  validation {
    condition     = var.enable_deep_monitoring == null
    error_message = "enable_deep_monitoring was removed: renamed to enable_alarms (default true). Delete it from terraform.tfvars."
  }
}
