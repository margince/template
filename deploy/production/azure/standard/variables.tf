variable "azure_region" {
  description = <<-EOT
    Azure region every resource is created in. Defaults to "westeurope"
    because it has long-established support for every service this stack
    uses: Container Apps, Premium ACR with a customer-managed key, and
    Postgres Flexible Server zone-redundant HA. For a Germany-specific
    data-residency requirement, override it (e.g. "germanywestcentral") after
    confirming each service is generally available there.
  EOT
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Name of the resource group every resource in this stack is created in."
  type        = string
  default     = "margince"
}

variable "name_prefix" {
  description = "Short prefix for every resource name (e.g. \"margince-prod\"). Globally unique names add a random suffix (naming.tf)."
  type        = string
  default     = "margince"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,12}$", var.name_prefix))
    error_message = "name_prefix: 3-13 characters, lowercase letters, digits and hyphens, starting with a letter (storage and key vault names have length limits)."
  }
}

variable "environment" {
  description = <<-EOT
    Value of every resource's Environment tag (network.tf's
    local.common_tags). Lets cost and operations tools tell environments apart
    when the same name_prefix is reused (a staging copy of "margince", say).
  EOT
  type        = string
  default     = "production"
}

variable "vnet_cidr" {
  description = "Address space for the virtual network this stack creates."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = <<-EOT
    Number of Availability Zones the zone-redundant resources spread across
    (the Container Apps environment, Postgres ZoneRedundant HA). It does not
    create per-zone subnets: Azure subnets are regional, so one subnet per
    tier covers every zone. See network.tf's NAT egress comment for the
    zone-resilience gap there.
  EOT
  type        = number
  default     = 2
  validation {
    condition     = var.az_count >= 2
    error_message = "az_count must be at least 2: the api spreads across zones, and Postgres ZoneRedundant HA (db_zone_redundant_ha) needs a primary and a standby zone."
  }
}

# ---- Images ---------------------------------------------------------------

variable "image_tag" {
  description = <<-EOT
    Tag to deploy for all three roles (api, worker, web): a real release
    version (e.g. a git SHA or MARGINCE_RELEASE_VERSION), never "latest".
    ACR has no Terraform-managed setting that refuses a re-push to an
    existing tag (see acr.tf), so "no latest" is a release convention, not
    something the registry enforces. No default: choosing a tag is an
    operator decision.
  EOT
  type        = string
  validation {
    condition     = length(trimspace(var.image_tag)) > 0
    error_message = "image_tag must not be empty or whitespace."
  }
}

# ---- Compute sizing ---------------------------------------------------------
# Container Apps does not expose a CPU architecture choice, so there is no
# architecture variable.

variable "api_min_replicas" {
  description = "Replicas of the api app. Each replica runs cmd/api plus the edge (nginx) container that serves the SPA and is the public entry, so this is also the web tier's replica count. Never scales to zero."
  type        = number
  default     = 3
}

variable "api_max_replicas" {
  description = "Upper bound for the api app's CPU and HTTP concurrency scale rules."
  type        = number
  default     = 6
}

variable "api_http_concurrent_requests" {
  description = "Concurrent requests per api replica before the HTTP scale rule adds a replica."
  type        = number
  default     = 50
}

variable "enable_mtls" {
  description = "Peer-to-peer mTLS between apps in the Container Apps environment (public preview; adds latency). Off by default: only the api app has ingress."
  type        = bool
  default     = false
}

variable "worker_min_replicas" {
  description = <<-EOT
    Defaults to 1. worker runs River's periodic jobs (the 30-second capture
    sync dispatcher among them) and has no ingress, so nothing but its own
    CPU rule could wake it from zero, and a CPU rule has no replica to sample
    at zero (containerapps.tf's own comment). At 0, mailbox capture, AI jobs
    and every other background job would never run.
  EOT
  type        = number
  default     = 1
}

variable "worker_max_replicas" {
  type    = number
  default = 3
}

# vCPU/memory pairs must add up to one of Container Apps' fixed Consumption
# combinations (learn.microsoft.com/azure/container-apps/containers#allocations).
# Each default pair is valid; 0.5 vCPU : 1 GiB suits the api and worker.
variable "api_cpu" {
  type    = number
  default = 0.5
}

variable "api_memory" {
  type    = string
  default = "1Gi"
}

variable "worker_cpu" {
  type    = number
  default = 0.5
}

variable "worker_memory" {
  type    = string
  default = "1Gi"
}

variable "web_cpu" {
  description = "CPU of the edge (nginx + SPA) container inside the api app. api_cpu + web_cpu must, with the memory pair, form a valid Consumption combination."
  type        = number
  default     = 0.25
}

variable "web_memory" {
  description = "Memory of the edge container inside the api app (see web_cpu)."
  type        = string
  default     = "0.5Gi"
}

variable "log_retention_days" {
  description = "Log Analytics retention, including Key Vault and file-share audit logs."
  type        = number
  default     = 90
}

variable "acr_untagged_manifest_retention_days" {
  description = <<-EOT
    Days before acr.tf's retention policy deletes an untagged manifest (the
    previous digest, once a tag moves). ACR has no rule to keep only the N
    most recent tagged images; see acr.tf.
  EOT
  type        = number
  default     = 14
}

# ---- Database ---------------------------------------------------------------

variable "db_sku_name" {
  description = <<-EOT
    Postgres Flexible Server SKU, "tier_Family+size". B_Standard_B2s (2 vCPU,
    4 GiB) rather than B_Standard_B1ms (1 vCPU, 2 GiB): the cheapest
    Burstable size with 2 vCPU and 4 GiB. Microsoft recommends General
    Purpose for production: "GP_Standard_D2ds_v5" (about +EUR 75/month) gives
    steady CPU and allows db_zone_redundant_ha.
  EOT
  type        = string
  default     = "B_Standard_B2s"
}

variable "db_storage_mb" {
  description = <<-EOT
    Postgres Flexible Server only accepts storage_mb from a fixed list
    (documented on azurerm_postgresql_flexible_server). 65536 (64 GiB) is the
    smallest listed value at or above 50 GiB. Initial size only: auto-grow
    extends it later and Terraform ignores the difference.
  EOT
  type        = number
  default     = 65536
}

variable "db_version" {
  description = "Postgres major version. Must be a version Azure lists pgvector support for."
  type        = string
  default     = "16"
}

variable "db_zone_redundant_ha" {
  description = <<-EOT
    Zone-redundant high availability (one standby in another zone). Off by
    default: Azure offers HA only on General Purpose and Memory Optimized
    SKUs, not on the Burstable default, and 7-day point-in-time restore
    already covers a 40-user installation. To turn it on, also set db_sku_name
    to e.g. "GP_Standard_D2ds_v5" (about +EUR 75/month for the SKU, then
    about +EUR 140/month for the standby).
  EOT
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

variable "postgres_entra_admin_object_id" {
  description = "Object ID of an Entra user, group or service principal made Postgres Entra administrator. Empty: no Entra administrator (Entra sign-in stays enabled)."
  type        = string
  default     = ""
}

variable "postgres_entra_admin_name" {
  description = "Display name (user principal name for a user) of postgres_entra_admin_object_id."
  type        = string
  default     = ""
}

variable "postgres_entra_admin_type" {
  description = "Principal type of postgres_entra_admin_object_id: User, Group or ServicePrincipal."
  type        = string
  default     = "Group"
  validation {
    condition     = contains(["User", "Group", "ServicePrincipal"], var.postgres_entra_admin_type)
    error_message = "postgres_entra_admin_type must be User, Group or ServicePrincipal."
  }
}

# ---- Redis (container app, redis.tf) ------------------------------------------

variable "redis_image" {
  description = "Redis image, pinned by digest. Margince needs Redis 7.0-7.2; this is the image its development stack uses."
  type        = string
  default     = "docker.io/library/redis:7.2@sha256:6461ca4ac0c5c9d81d53685c3bf76aa81f464a9de6cf3a97b80a1da8d1bb1de4"
}

variable "redis_cpu" {
  type    = number
  default = 0.5
}

variable "redis_memory" {
  description = "Container memory. Keep redis_maxmemory well below it."
  type        = string
  default     = "1Gi"
}

variable "redis_maxmemory" {
  description = "Redis maxmemory. With noeviction, writes fail at this limit instead of the container being OOM-killed."
  type        = string
  default     = "768mb"
}

variable "redis_share_quota_gb" {
  description = "Azure Files share holding the Redis AOF and RDB files (/data). Billed on use, not quota."
  type        = number
  default     = 16
}

# ---- Public entry (the api app's edge container) ------------------------------------
# There is no gateway in front of this stack. The api app is the one app with
# external ingress, and its ingress targets the edge (nginx) container, which
# serves the SPA and forwards api paths to cmd/api on localhost
# (templates/edge-nginx.conf.tftpl).

variable "bind_custom_domain" {
  description = <<-EOT
    Binds public_base_url's host to the web app. Leave false on the FIRST
    apply: Container Apps refuses the binding until the domain's DNS already
    carries the asuid TXT record (value: the custom_domain_verification_id
    output) and a CNAME to the public_default_fqdn output, and neither exists
    before the environment does. Create both records, then set true and apply
    again. The managed certificate is issued afterwards by one
    `az containerapp hostname bind` call (README.md).
  EOT
  type        = bool
  default     = false
}

variable "break_glass_cidrs" {
  description = <<-EOT
    Source ranges allowed to use password login (POST /v1/auth/login). Every
    other client gets 403 from nginx, so staff can only sign in through Entra
    ID, where the customer's Conditional Access policy applies. Keep this to
    the one admin network that holds the break-glass account. Empty blocks
    password login for everyone.
  EOT
  type        = list(string)
  default     = []
}

variable "auth_rate_limit_per_minute" {
  description = "Requests per minute per client address that nginx allows on password login, password reset, OAuth token and first-run setup paths (burst of the same size). Staff behind one office NAT share one address, so keep headroom above the head count."
  type        = number
  default     = 30
}

variable "public_base_url" {
  description = "MARGINCE_PUBLIC_BASE_URL — e.g. https://crm.example.com. Its host is the custom domain bound to the web app, and the base of every Entra redirect URI."
  type        = string
  validation {
    condition     = can(regex("^https://[a-z0-9.-]+$", var.public_base_url))
    error_message = "public_base_url must be https://<host> with no path or trailing slash."
  }
}

# ---- Entra ID (the customer's existing tenant) ------------------------------------

variable "create_entra_app" {
  description = <<-EOT
    true: entra.tf creates the single-tenant app registration Margince signs
    staff in with (and captures mail through), requires assignment on its
    enterprise app, assigns entra_access_group_object_id to it, and seals a
    client secret into Key Vault. Needs the Terraform identity to hold
    Application Administrator in Entra.
    false: an Entra admin creates the app by hand (README.md) and passes
    entra_client_id and entra_client_secret instead.
  EOT
  type        = bool
  default     = true
}

variable "entra_access_group_object_id" {
  description = <<-EOT
    Object ID of the Entra security group allowed to use Margince. Reuse the
    group that already gates the customer's Dataverse environment, so one
    group membership decides access to both. Required when create_entra_app
    is true.
  EOT
  type        = string
  default     = ""
}

variable "entra_client_id" {
  description = "Application (client) ID of a hand-made app registration. Read only when create_entra_app is false."
  type        = string
  default     = ""
}

variable "entra_client_secret" {
  description = "Client secret of a hand-made app registration. Read only when create_entra_app is false."
  type        = string
  default     = ""
  sensitive   = true
}

variable "entra_secret_rotation_days" {
  description = "Lifetime of the client secret entra.tf creates. Terraform replaces it on the first apply after this many days; plan an apply before it expires."
  type        = number
  default     = 180
}

variable "entra_grant_admin_consent" {
  description = <<-EOT
    true grants tenant-wide admin consent for the delegated Microsoft Graph
    permissions entra.tf requests. Needs the Terraform identity to hold
    Privileged Role Administrator or Global Administrator. Leave false to have
    an Entra admin click "Grant admin consent" in the portal instead.
  EOT
  type        = bool
  default     = false
}


# ---- Secrets and application config -----------------------------------------

variable "license_token" {
  description = "MARGINCE_LICENSE. Empty runs unlicensed, which a production role refuses to boot on."
  type        = string
  default     = ""
  sensitive   = true
}

variable "admin_bootstrap_password" {
  description = <<-EOT
    MARGINCE_ADMIN_PASSWORD for the first boot against an empty database.
    Rotate/remove per docs/deployment.md once the organization exists — this
    variable only seeds the initial secret version.
  EOT
  type        = string
  sensitive   = true
}

variable "enable_deep_monitoring" {
  description = <<-EOT
    Turns on alarms.tf's action group and metric alerts (Postgres CPU,
    storage and CPU credits, api 5xx, api/worker/redis restarts).
    Log Analytics and every resource's diagnostic settings stay on
    regardless; this only controls alerting.
  EOT
  type        = bool
  default     = true
}

variable "alert_email" {
  description = <<-EOT
    Optional email address added to alarms.tf's action group. Only read when
    enable_deep_monitoring is true. Empty by default: the alert destination
    is the operator's to choose.
  EOT
  type        = string
  default     = ""
}

# ---- Operator access and image builds -------------------------------------------

variable "key_vault_admin_principal_ids" {
  description = <<-EOT
    Entra object ids granted Key Vault Administrator on this stack's vault,
    ideally one group that holds every operator and the CI identity. Whoever
    runs terraform apply must be covered, or the secret writes fail. Empty:
    the identity running apply, which only works while one person applies.
  EOT
  type        = list(string)
  default     = []
}

variable "operator_ip_allowlist" {
  description = <<-EOT
    Public IPv4 addresses (plain addresses, no /prefix) allowed through the
    public endpoints of Key Vault, the Storage Account and the container
    registry while you set the stack up or push images from a laptop
    (scripts/build-images.sh local). Each service keeps default-deny and its
    private endpoint; only these addresses are let in. Leave empty in steady
    state: the three services then have no public endpoint at all. Postgres
    and Redis are never reachable this way; use the jumpbox for Postgres.
  EOT
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for ip in var.operator_ip_allowlist : can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", ip))])
    error_message = "operator_ip_allowlist takes plain IPv4 addresses such as 203.0.113.10 (Storage rejects /31 and /32 prefixes)."
  }
}

variable "enable_jumpbox" {
  description = <<-EOT
    Creates a small Linux VM inside the VNet (jumpbox.tf) with Docker, Azure
    CLI, Terraform and psql: the "cloud" image build path
    (scripts/build-images.sh cloud), the database bootstrap, and anything
    else that must reach the private endpoints. No public IP; reach it with
    Azure Bastion Developer (enable_bastion_developer) or
    `az vm run-command`. Shuts down every evening (jumpbox_shutdown_time).
  EOT
  type        = bool
  default     = true
}

variable "enable_bastion_developer" {
  description = "Adds Azure Bastion's free Developer tier for browser SSH to the jumpbox from the Azure portal. Read only when enable_jumpbox is true."
  type        = bool
  default     = true
}

variable "jumpbox_vm_size" {
  description = "2 vCPU / 8 GiB builds the Go and web images in a few minutes. Billed only while running."
  type        = string
  default     = "Standard_B2ms"
}

variable "jumpbox_admin_username" {
  type    = string
  default = "margince"
}

variable "jumpbox_ssh_public_key" {
  description = "OpenSSH public key (ssh-ed25519 or ssh-rsa) for jumpbox_admin_username. Password login is disabled. Required when enable_jumpbox is true."
  type        = string
  default     = ""
  validation {
    condition     = var.jumpbox_ssh_public_key == "" || startswith(var.jumpbox_ssh_public_key, "ssh-rsa ") || startswith(var.jumpbox_ssh_public_key, "ssh-ed25519 ")
    error_message = "jumpbox_ssh_public_key must be an ssh-ed25519 or ssh-rsa public key."
  }
}

variable "encryption_at_host" {
  description = <<-EOT
    Encrypts the jumpbox's temp disk and disk caches on the host. Needs the
    subscription feature once:
      az feature register --namespace Microsoft.Compute --name EncryptionAtHost
      az provider register --namespace Microsoft.Compute
  EOT
  type        = bool
  default     = true
}

variable "jumpbox_shutdown_time" {
  description = "Daily automatic shutdown, HHMM in jumpbox_shutdown_timezone. Start it again with `az vm start` or scripts/build-images.sh cloud."
  type        = string
  default     = "2000"
}

variable "jumpbox_shutdown_timezone" {
  type    = string
  default = "W. Europe Standard Time"
}

# ---- Attachments ---------------------------------------------------------------

variable "attachments_share_quota_gb" {
  description = <<-EOT
    Size of the Azure Files share mounted read-write into api and worker as
    MARGINCE_BLOBSTORE_PATH (Margince's filesystem attachment store), until a
    native Azure Blob adapter exists. Billed on use, not quota.
  EOT
  type        = number
  default     = 100
}

# ---- Deployment flow ---------------------------------------------------------------

variable "deploy_apps" {
  description = <<-EOT
    false on the first apply: everything except the Container Apps is
    created. Set true once the images are pushed, the database bootstrapped
    and margince.yaml uploaded (README.md), so no revision starts before its
    prerequisites exist.
  EOT
  type        = bool
  default     = false
}

variable "environment_posture" {
  description = <<-EOT
    "production" requires license_token (the api refuses to boot unlicensed).
    "development" sets MARGINCE_ENV=dev for test installations.
  EOT
  type        = string
  default     = "production"
  validation {
    condition     = contains(["production", "development"], var.environment_posture)
    error_message = "environment_posture must be \"production\" or \"development\"."
  }
}

variable "include_bootstrap_admin" {
  description = "Passes the bootstrap admin password to the api for the first boot. Set false once the first admin has signed in and changed it (README.md)."
  type        = bool
  default     = true
}

variable "image_digests" {
  description = <<-EOT
    Optional map of role => image digest ("sha256:..."), for api, worker and
    web. When set for a role, that role is deployed by digest, which a later
    push cannot change. scripts/build-images.sh prints the digests.
  EOT
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for d in values(var.image_digests) : can(regex("^sha256:[a-f0-9]{64}$", d))])
    error_message = "image_digests values must look like sha256:<64 hex characters>."
  }
}

# ---- Encryption and protection ---------------------------------------------------

variable "postgres_customer_managed_key" {
  description = "Encrypts Postgres with this stack's Key Vault key. Verify in a test subscription that the server can reach the firewalled vault; set false to use Microsoft-managed keys."
  type        = bool
  default     = true
}

variable "registry_customer_managed_key" {
  description = <<-EOT
    Encrypts the container registry with this stack's Key Vault key. Off by
    default: the registry holds images, not customer data, and ACR documents
    firewalled-vault access for its system-assigned identity only, while this
    stack uses a user-assigned one.
  EOT
  type        = bool
  default     = false
}

variable "storage_smb_hardening" {
  description = "Restricts Azure Files to SMB 3.1.1, AES-256-GCM channel encryption and NTLMv2. Off by default: not documented for Container Apps mounts; test before enabling."
  type        = bool
  default     = false
}

variable "enable_resource_locks" {
  description = "CanNotDelete locks on Postgres, the storage account, Key Vault, the Recovery Services vault and ACR. Remove them (set false and apply) before terraform destroy."
  type        = bool
  default     = true
}

variable "enable_vnet_flow_logs" {
  description = "VNet flow logs to the storage account, kept 90 days. Needs Network Watcher enabled in the region (NetworkWatcher_<region> in NetworkWatcherRG, created by Azure with the first VNet)."
  type        = bool
  default     = true
}

variable "enable_traffic_analytics" {
  description = "Traffic analytics on the VNet flow logs, into the Log Analytics workspace (billed per GB processed). Read only when enable_vnet_flow_logs is true."
  type        = bool
  default     = true
}

variable "enable_attachments_backup" {
  description = "Daily Azure Backup of the attachments and redis shares, kept 30 days (Recovery Services vault). Share soft delete is always on."
  type        = bool
  default     = true
}
