variable "aws_region" {
  description = "AWS region every resource is created in."
  type        = string
  default     = "eu-central-1"
}

variable "name_prefix" {
  description = "Short prefix for every resource name (e.g. \"margince-light\")."
  type        = string
  default     = "margince-light"
}

variable "environment" {
  description = <<-EOT
    Stamped onto every resource's Environment tag (provider default_tags,
    versions.tf) — the dimension a cost/operations tool groups this stack's
    spend by when the same name_prefix is reused across more than one
    environment.
  EOT
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC this stack creates."
  type        = string
  default     = "10.30.0.0/16"
}

variable "az_count" {
  description = <<-EOT
    Number of AZs the PRIVATE subnets (the RDS subnet group) spread across.
    The compute itself — three EC2 instances (edge/app/worker), always — sits
    in one public subnet; this only sizes the RDS side. An RDS subnet group
    requires subnets in at least two AZs even for a single-AZ instance,
    which is why this floor is 2 rather than 1.
  EOT
  type        = number
  default     = 2
  validation {
    condition     = var.az_count >= 2
    error_message = "az_count must be at least 2 — the RDS subnet group requires two Availability Zones."
  }
}

variable "cpu_architecture" {
  description = <<-EOT
    Instance/image architecture — "x86_64" or "arm64". Defaults to arm64
    (Graviton, e.g. t4g.small): RDS (db.t4g.micro) and ElastiCache
    (cache.t4g.micro) already default to Graviton families, the product's
    own release pipeline builds and smoke-tests every image on real arm64
    GitHub runners and pushes multi-arch (linux/amd64,linux/arm64) images,
    and the backend has zero cgo. Set to "x86_64" if your own build/push
    step only produces an amd64 image — this also picks the matching
    Amazon Linux 2023 AMI via the SSM parameter in ec2.tf.
  EOT
  type        = string
  default     = "arm64"
  validation {
    condition     = contains(["x86_64", "arm64"], var.cpu_architecture)
    error_message = "cpu_architecture must be \"x86_64\" or \"arm64\"."
  }
}

# ---- Images -------------------------------------------------------------

variable "image_tag" {
  description = <<-EOT
    Release identifier for all three roles (edge/app/worker) — a real
    version (e.g. a git SHA or MARGINCE_RELEASE_VERSION), never "latest".
    Each instance checks its own S3 artifact cache
    (build.tf/templates/user_data-*.sh.tpl) for `binaries/<role>-<tag>.tar.gz`
    first; if missing, it compiles from source and publishes that key
    itself. No default: picking a floating tag is an operator decision this
    stack should not make silently.
  EOT
  type        = string
  validation {
    condition     = length(trimspace(var.image_tag)) > 0
    error_message = "image_tag must not be empty or whitespace."
  }
}

# ---- Compute sizing -------------------------------------------------------

variable "instance_type" {
  description = <<-EOT
    Shared across all three instances (edge/app/worker, ec2.tf) — each runs
    ONE role's process plus its own build toolchain (Go always; edge also
    needs Node/pnpm for the frontend). t4g.small (2 vCPU / 2GiB) is the
    floor that leaves headroom for a from-source compile on top of the
    running process; t4g.micro (1GiB) starves the build. Burstable
    (T-family): fine for a light/small-deployment workload, not for one
    under sustained load — size up (m7g family) if CPU credit balance
    becomes the bottleneck. Must match cpu_architecture: Graviton families
    end in "g" before the size suffix (t4g, m7g, etc.).
  EOT
  type        = string
  default     = "t4g.small"

  validation {
    condition     = var.cpu_architecture != "x86_64" || !can(regex("^(a1|[a-z]+[0-9]+g[a-z]*)\\.", var.instance_type))
    error_message = "instance_type \"${var.instance_type}\" is a Graviton (arm64) family; set cpu_architecture = \"arm64\" or pick an x86_64 instance type."
  }
  validation {
    condition     = var.cpu_architecture != "arm64" || can(regex("^(a1|[a-z]+[0-9]+g[a-z]*)\\.", var.instance_type))
    error_message = "instance_type \"${var.instance_type}\" does not look like a Graviton (arm64) family (e.g. t4g.small, m7g.large, c7gd.large, c7gn.large); set cpu_architecture = \"x86_64\" or choose an arm64 instance type."
  }
}

variable "root_volume_gb" {
  description = <<-EOT
    Shared across all three instances. 40 leaves headroom for the Go module
    cache (every instance) and node_modules/pnpm store (edge only) a
    from-source build (templates/user_data-*.sh.tpl) needs on top of the
    running process, on a boot where its S3 artifact cache is empty.
  EOT
  type        = number
  default     = 40
}

variable "admin_bootstrap_password" {
  description = <<-EOT
    MARGINCE_ADMIN_PASSWORD for the first boot against an empty database.
    Rotate/remove per the Margince repository's docs/deployment.md once the organization exists —
    this variable only seeds the initial SSM parameter value.
  EOT
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.admin_bootstrap_password) > 0
    error_message = "admin_bootstrap_password must not be empty (SSM Parameter Store rejects empty values)."
  }
}

variable "license_token" {
  description = "MARGINCE_LICENSE. Empty runs unlicensed, which a production role refuses to boot on."
  type        = string
  default     = ""
  sensitive   = true
}

variable "public_base_url" {
  description = <<-EOT
    MARGINCE_PUBLIC_BASE_URL, e.g. https://crm.example.com. Its host is what
    CloudFront (cloudfront.tf) requests an ACM certificate for and what
    nginx's server_name matches (ec2.tf's `local.domain`) — this domain's
    DNS must eventually CNAME to cloudfront_domain_name (see README); ACM's
    own DNS validation is a separate, earlier manual step (cloudfront.tf).
  EOT
  type        = string
}

# ---- Database ---------------------------------------------------------------

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_allocated_storage_gb" {
  type    = number
  default = 20
}

variable "db_engine_version" {
  description = "Postgres major version (\"16\"). Major only: RDS applies minor upgrades itself (auto_minor_version_upgrade), and a pinned minor makes every later plan try to downgrade. Must be a major RDS lists pgvector support for."
  type        = string
  default     = "16"
}

variable "db_backup_retention_days" {
  description = "Shorter than the full stack's default (7) on purpose — this is the light/small-deployment option, not the one asked to hold a long rollback window."
  type        = number
  default     = 3
}

variable "db_final_snapshot_generation" {
  description = <<-EOT
    Feeds rds.tf's random_id.final_snapshot as a keepers value, so a
    deliberate replacement gets a fresh final-snapshot suffix without
    deriving it from the resource being deleted (which would cycle). Bump
    this before destroying and recreating the RDS instance in the SAME
    state — otherwise the reused suffix collides with a snapshot an earlier
    deletion already left behind. ElastiCache has no equivalent here: this
    stack's replication group takes no final snapshot at all (elasticache.tf).
  EOT
  type        = number
  default     = 1
}

# ---- Observability -----------------------------------------------------------

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "enable_alarms" {
  description = <<-EOT
    Creates alarms.tf's SNS topic and CloudWatch alarms: per instance
    (edge/app/worker) system status check with EC2 auto-recover, instance
    status check, sustained CPU; RDS free storage, CPU and connections. On
    by default: every role is a single instance with no peer, so these are
    the only signal that something is down. Standard-resolution alarms on
    free basic metrics, roughly $0.10/alarm/month.
  EOT
  type        = bool
  default     = true
}

variable "alert_email" {
  description = <<-EOT
    Optional email address subscribed to the alerts SNS topic. Empty (the
    default) creates no subscription. AWS emails a confirmation link that
    must be clicked before any alert is delivered.
  EOT
  type        = string
  default     = ""
  validation {
    condition     = var.alert_email == "" || can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must be empty or a single email address."
  }
}

variable "db_max_connections_alarm_threshold" {
  description = <<-EOT
    DatabaseConnections above this for 15 minutes alarms. db.t4g.micro's
    default max_connections is roughly 80-110 (derived from instance
    memory); raise this with a larger db_instance_class.
  EOT
  type        = number
  default     = 70
}

# ---- Source -----------------------------------------------------------------

variable "margince_source_dir" {
  description = <<-EOT
    Path to a checkout of the Margince source repository, at the commit to
    deploy. build.tf archives it (minus its .dockerignore exclusions) and
    uploads it to S3; each instance builds its own piece from that archive.
    The default assumes the Margince repository sits next to this repository's
    checkout (five levels up from deploy/production/aws/light).
  EOT
  type        = string
  default     = "../../../../../margince"
  validation {
    condition     = fileexists("${var.margince_source_dir}/Dockerfile")
    error_message = "margince_source_dir must point at a Margince source checkout (no Dockerfile found there)."
  }
}

variable "auth_rate_limit_per_minute" {
  description = "Requests per minute per client address nginx allows on login, password reset, OAuth token and setup paths (burst of the same size). Same rule set as the Azure light stack."
  type        = number
  default     = 30
  validation {
    condition     = var.auth_rate_limit_per_minute >= 1
    error_message = "auth_rate_limit_per_minute must be at least 1."
  }
}

# Removed. Declared only so an old terraform.tfvars entry fails with a clear
# message; Terraform would otherwise ignore it with a warning.
variable "enable_waf" {
  description = "Removed: light has no WAF by design; nginx on edge rate-limits the credential endpoints."
  type        = any
  default     = null
  validation {
    condition     = var.enable_waf == null
    error_message = "enable_waf was removed: light has no WAF by design; nginx on edge rate-limits the credential endpoints. Delete it from terraform.tfvars."
  }
}

# Removed. Declared only so an old terraform.tfvars entry fails with a clear
# message; Terraform would otherwise ignore it with a warning.
variable "enable_deep_monitoring" {
  description = "Removed: renamed to enable_alarms (default true)."
  type        = any
  default     = null
  validation {
    condition     = var.enable_deep_monitoring == null
    error_message = "enable_deep_monitoring was removed: renamed to enable_alarms (default true). Delete it from terraform.tfvars."
  }
}
