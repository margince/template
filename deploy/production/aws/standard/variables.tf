variable "aws_region" {
  description = "AWS region every resource is created in."
  type        = string
  default     = "eu-central-1"
}

variable "name_prefix" {
  description = "Short prefix for every resource name (e.g. \"margince-prod\")."
  type        = string
  default     = "margince"
}

variable "environment" {
  description = <<-EOT
    Stamped onto every resource's Environment tag (provider default_tags,
    versions.tf) — the dimension a cost/operations tool groups this stack's
    spend and automation by when the same name_prefix is reused across more
    than one environment (a staging copy of "margince", say).
  EOT
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC this stack creates."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread public/private subnets across."
  type        = number
  default     = 2
  validation {
    # RDS and ElastiCache subnet groups both require subnets in at least two
    # AZs — az_count = 1 produces a db_subnet_group covering one, which RDS
    # refuses at CreateDBSubnetGroup, not at plan time, so this catches it
    # before the apply gets that far.
    condition     = var.az_count >= 2
    error_message = "az_count must be at least 2 — RDS and ElastiCache subnet groups both require two Availability Zones."
  }
}

variable "cpu_architecture" {
  description = <<-EOT
    Fargate runtime_platform.cpu_architecture for all three task definitions
    — "X86_64" or "ARM64". Defaults to ARM64 (Graviton): RDS (db.t4g.medium)
    and ElastiCache (cache.t4g.small) already default to Graviton instance
    families, the product's own release pipeline already builds and
    smoke-tests every image on real arm64 GitHub runners
    (.github/workflows/release.yml) and pushes multi-arch
    (linux/amd64,linux/arm64) images, the backend has zero cgo, and the
    Dockerfile cross-compiles via TARGETARCH already — Fargate on Graviton
    also runs meaningfully cheaper than x86_64 at the same vCPU/memory. Set
    to X86_64 if your own build/push step (README.md step 3) only produces
    an amd64 image.
  EOT
  type        = string
  default     = "ARM64"
  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be \"X86_64\" or \"ARM64\"."
  }
}

# ---- Images -------------------------------------------------------------

variable "image_tag" {
  description = <<-EOT
    Tag to deploy for all three roles (api, worker, web) — a real release
    version (e.g. a git SHA or MARGINCE_RELEASE_VERSION), never "latest".
    The ECR repos are image_tag_mutability = IMMUTABLE (ecs.tf), so a tag can
    only ever be pushed once; "latest" would work for exactly one release and
    then refuse every push after it, which is the immutability doing its job
    rather than a bug. Push the tag to the ECR repos this stack creates
    before the first `terraform apply` that references it — ECS refuses to
    start a task against a tag that does not exist yet. No default: picking a
    floating tag is an operator decision this stack should not make silently.
  EOT
  type        = string
  validation {
    # An empty or whitespace image_tag builds "repo:" — no tag at all — which
    # ECS rejects rather than defaulting to anything, so this fails fast at
    # plan time with a message that names the actual problem. "latest" is
    # deliberately still admitted: it is valid for exactly one push to an
    # IMMUTABLE repo (see the description above), which is a release-policy
    # violation this stack warns about elsewhere, not a value that breaks
    # the deployment outright.
    condition     = length(trimspace(var.image_tag)) > 0
    error_message = "image_tag must not be empty or whitespace — ECS needs repository:tag, not repository:."
  }
}

# ---- Compute sizing -------------------------------------------------------

variable "api_desired_count" {
  type    = number
  default = 2
}

variable "worker_desired_count" {
  type    = number
  default = 1
}

variable "api_autoscaling_max_count" {
  description = "Ceiling for api's CPU-based Application Auto Scaling target (ecs.tf) — api_desired_count is the floor."
  type        = number
  default     = 4
}

variable "worker_autoscaling_max_count" {
  description = "Ceiling for worker's CPU-based Application Auto Scaling target (ecs.tf) — worker_desired_count is the floor."
  type        = number
  default     = 3
}

variable "web_desired_count" {
  type    = number
  default = 2
}

variable "api_cpu" {
  type    = number
  default = 512
}

variable "api_memory" {
  type    = number
  default = 1024
}

variable "worker_cpu" {
  type    = number
  default = 512
}

variable "worker_memory" {
  type    = number
  default = 1024
}

variable "web_cpu" {
  type    = number
  default = 256
}

variable "web_memory" {
  type    = number
  default = 512
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "ecr_tagged_image_retain_count" {
  description = <<-EOT
    ecs.tf's ECR lifecycle policy expires all but the most recent N tagged
    (released) images per repo, once IMMUTABLE tag mutability (ecs.tf) means
    none of them are ever reclaimed by a later push to the same tag. 30 is a
    generous rollback window for a CRM's release cadence, not a tuned value
    — raise it if you release more often than that and still want that many
    rollback targets on hand. Must be a positive integer.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.ecr_tagged_image_retain_count >= 1 && floor(var.ecr_tagged_image_retain_count) == var.ecr_tagged_image_retain_count
    error_message = "ecr_tagged_image_retain_count must be a positive integer."
  }
}

# ---- Database ---------------------------------------------------------------

variable "db_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "db_allocated_storage_gb" {
  type    = number
  default = 50
}

variable "db_engine_version" {
  description = "Postgres major version (\"16\"). Major only: RDS applies minor upgrades itself (auto_minor_version_upgrade), and a pinned minor makes every later plan try to downgrade. Must be a major RDS lists pgvector support for."
  type        = string
  default     = "16"
}

variable "db_multi_az" {
  type    = bool
  default = true
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

variable "db_final_snapshot_generation" {
  description = <<-EOT
    Feeds rds.tf's random_id.final_snapshot and elasticache.tf's
    random_id.redis_final_snapshot as a keepers value, so each gets a fresh
    final-snapshot suffix without deriving it from the resource being
    deleted (which would cycle). Bump this before deliberately destroying
    and recreating the RDS instance or the Redis replication group in the
    SAME state — otherwise the reused suffix collides with a snapshot an
    earlier deletion already left behind, and RDS/ElastiCache reject the
    delete with a snapshot-already-exists error. A replacement Terraform
    triggers on its own (e.g. a ForceNew attribute change) does not need
    this bumped, since that recreates the random_id resource too.
  EOT
  type        = number
  default     = 1
}

# ---- Redis ------------------------------------------------------------------

variable "redis_node_type" {
  type    = string
  default = "cache.t4g.small"
}

# ---- Routing ------------------------------------------------------------------

variable "acm_certificate_arn" {
  description = <<-EOT
    ARN of an ACM certificate covering the public host this installation
    serves (MARGINCE_PUBLIC_BASE_URL's host). Not created by this stack —
    validating a certificate needs the domain's own DNS, which lives
    wherever the operator's zone lives.
  EOT
  type        = string
}

variable "public_base_url" {
  description = "MARGINCE_PUBLIC_BASE_URL — e.g. https://crm.example.com"
  type        = string
}

# ---- Secrets and application config -----------------------------------------

variable "license_token" {
  description = "MARGINCE_LICENSE. Empty runs unlicensed (no SSM parameter is created and the variable is left unset in the task), which a production role refuses to boot on."
  type        = string
  default     = ""
  sensitive   = true
}

variable "admin_bootstrap_password" {
  description = <<-EOT
    MARGINCE_ADMIN_PASSWORD for the first boot against an empty database.
    Rotate/remove per the Margince repository's docs/deployment.md once the organization exists —
    this variable only seeds the initial SSM parameter value (secrets.tf
    ignores later changes so an operator overwrite survives apply).
  EOT
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.admin_bootstrap_password) > 0
    error_message = "admin_bootstrap_password must not be empty; SSM cannot store an empty value."
  }
}

# ---- Observability -----------------------------------------------------------

variable "enable_alarms" {
  description = <<-EOT
    Toggles alarms.tf: the CMK-encrypted SNS topic and the baseline alarm
    set (ALB 5xx / unhealthy targets / p95 latency, ECS CPU and memory, RDS
    storage / CPU / connections, ElastiCache memory / CPU, WAF blocked
    requests, and CPU-credit balance on burstable instance classes). On by
    default: a production stack with no alerting fails silently. Set
    alert_email, or subscribe your own endpoint to the alerts_topic_arn
    output, or alarms fire into a topic nobody reads.
  EOT
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Email address subscribed to the alerts SNS topic. Empty creates no subscription. AWS sends a confirmation mail; alarms are not delivered until it is confirmed."
  type        = string
  default     = ""
}

variable "alarm_alb_5xx_threshold" {
  description = "ALB alarm: sum of HTTPCode_ELB_5XX_Count (and, separately, HTTPCode_Target_5XX_Count) per 5 minutes above which the alarm fires."
  type        = number
  default     = 25
}

variable "alarm_alb_p95_latency_seconds" {
  description = "ALB alarm: TargetResponseTime p95 in seconds, sustained for 15 minutes."
  type        = number
  default     = 2
}

variable "alarm_rds_max_connections" {
  description = <<-EOT
    RDS alarm: DatabaseConnections above this fires. The default is roughly
    80 percent of the max_connections Postgres derives for db.t4g.medium
    (LEAST(DBInstanceClassMemory/9531392, 5000), about 400). Raise it with
    db_instance_class.
  EOT
  type        = number
  default     = 320
}

variable "alarm_waf_blocked_requests_threshold" {
  description = "WAF alarm: BlockedRequests (all rules) per 5 minutes above which the alarm fires. Only meaningful once waf_mode = \"block\"; in count mode nothing is blocked."
  type        = number
  default     = 500
}

# ---- WAF --------------------------------------------------------------------

variable "waf_mode" {
  description = <<-EOT
    "count" or "block". In count mode every managed rule group and custom
    rule only counts matches (visible in the WAF log group and sampled
    requests) and nothing is blocked. Start in count, watch the logs for
    about a week for false positives on real traffic, add overrides where
    needed, then switch to "block". See README "WAF rollout".
  EOT
  type        = string
  default     = "count"
  validation {
    condition     = contains(["count", "block"], var.waf_mode)
    error_message = "waf_mode must be \"count\" or \"block\"."
  }
}

variable "waf_rate_limit_per_ip" {
  description = "Global per-IP request limit per 5-minute window, across all paths except the provider webhook paths."
  type        = number
  default     = 2000
  validation {
    condition     = var.waf_rate_limit_per_ip >= 10
    error_message = "WAF rate-based rules accept a limit of 10 or more."
  }
}

variable "waf_auth_rate_limit_per_ip" {
  description = "Per-IP request limit per 5-minute window on waf_auth_paths only (login, password reset, OAuth token and client registration)."
  type        = number
  default     = 100
  validation {
    condition     = var.waf_auth_rate_limit_per_ip >= 10
    error_message = "WAF rate-based rules accept a limit of 10 or more."
  }
}

variable "waf_auth_paths" {
  description = <<-EOT
    Exact URI paths the stricter auth rate limit applies to. Defaults are
    the api's credential-accepting endpoints (identity module middleware):
    password login, forgot/reset password, OAuth token and dynamic client
    registration. An optional trailing slash is matched too.
  EOT
  type        = list(string)
  default = [
    "/v1/auth/login",
    "/v1/auth/forgot-password",
    "/v1/auth/reset-password",
    "/oauth/token",
    "/oauth/register",
  ]
  validation {
    condition     = length(var.waf_auth_paths) > 0 && alltrue([for p in var.waf_auth_paths : startswith(p, "/")])
    error_message = "waf_auth_paths needs at least one path, each starting with /."
  }
}

variable "waf_allowed_country_codes" {
  description = <<-EOT
    ISO 3166-1 alpha-2 country codes allowed to reach the ALB (for example
    ["DE", "AT", "CH"]). Empty (default) disables geo filtering. The
    provider webhook paths are always exempt, since Google, Microsoft and
    HubSpot deliver from wherever their infrastructure runs.
  EOT
  type        = list(string)
  default     = []
}

variable "enable_waf_bot_control" {
  description = <<-EOT
    Adds the AWSManagedRulesBotControlRuleSet (COMMON inspection level).
    Extra cost on top of the web ACL: a monthly subscription fee plus a
    per-million-requests charge (see AWS WAF pricing). Off by default.
  EOT
  type        = bool
  default     = false
}

variable "waf_log_retention_days" {
  description = "Retention for the aws-waf-logs-<name_prefix> CloudWatch log group."
  type        = number
  default     = 30
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
