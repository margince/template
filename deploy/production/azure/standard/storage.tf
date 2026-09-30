# ---------------------------------------------------------------------------
# Attachments: the product's object-store client
# (backend/internal/platform/blobstore/s3.go) speaks the S3 API only, and
# Azure Blob Storage does not. Until an Azure Blob adapter exists, Margince
# stores attachments with its FILESYSTEM provider (blobstore/fs.go) on the
# attachments Azure Files share below, mounted read-write at /app/blobstore in
# api and worker (MARGINCE_BLOBSTORE_PATH, containerapps.tf). The blob
# container stays provisioned but unused, ready for that adapter.
#
# The filesystem store renames files and syncs directories; Margince treats
# the directory-sync errors CIFS can return as success
# (blobstore/fs_sync_unix.go). Upload and read back one attachment after the
# first deploy all the same.
# ---------------------------------------------------------------------------

# One storage account for the blob container and the file shares below.
# StorageV2 supports Blob and File in the same account, the same api/worker
# apps read both, and they share one CMK and private endpoint setup.
# Tradeoff: the blob lifecycle policy (below) does not reach the file shares,
# and Azure Files has no Terraform-managed lifecycle policy, so the config
# share is operator-managed once written.
resource "azurerm_storage_account" "this" {
  name                = "${local.flat_prefix}${local.suffix}data" # <= 24 lowercase alphanumerics
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  account_kind = "StorageV2"
  account_tier = "Standard"
  # ZRS, not LRS: the Container Apps environment is zone-redundant, and
  # Postgres can be (db_zone_redundant_ha); LRS would make the attachment
  # store a single-zone exception. Not GRS: the stack is
  # single-region by design, so cross-region replication here would buy a DR
  # posture nothing else has.
  account_replication_type = "ZRS"

  min_tls_version = "TLS1_2"
  # No object replication to storage accounts in other tenants.
  cross_tenant_replication_enabled = false
  # Enabled, with the network rules below denying everything except
  # operator_ip_allowlist and trusted Azure services (Azure Backup, flow-log
  # writes). With an empty allowlist nothing reaches it from the internet.
  # Storage honours no firewall exception while public access is disabled, so
  # disabling it would stop those services. Container Apps reach the shares
  # through the private endpoint either way.
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = var.operator_ip_allowlist
  }

  blob_properties {
    versioning_enabled = true

    # 30 days: an accidental delete/overwrite is recoverable without keeping
    # a soft-deleted blob forever — the container-level rule below covers a
    # deleted CONTAINER the same way.
    delete_retention_policy {
      days = 30
    }
    container_delete_retention_policy {
      days = 30
    }
  }

  # Soft delete for file shares (config, attachments): a deleted share can be
  # restored for 30 days.
  share_properties {
    retention_policy {
      days = 30
    }

    # No SMB protocol restrictions: Microsoft does not document Container
    # Apps Azure Files mounts with SMB 3.1.1-only / AES-256-GCM / NTLMv2.
    # Traffic stays on the private endpoint, and HTTPS-only plus TLS 1.2
    # still apply to the REST API.
  }

  # Same identity/key pattern as postgres.tf's customer_managed_key block — one shared data key (keyvault.tf), one
  # shared grant-holder identity (identity.tf's data_cmk).
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.data_cmk.id]
  }

  customer_managed_key {
    key_vault_key_id          = azurerm_key_vault_key.data.versionless_id
    user_assigned_identity_id = azurerm_user_assigned_identity.data_cmk.id
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-data", Component = "storage" })

  depends_on = [azurerm_role_assignment.data_cmk_key_vault_crypto_user]
}

resource "azurerm_storage_container" "blobstore" {
  name                  = "blobstore"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# Deletes noncurrent blob versions after 90 days (versioning_enabled above is
# what creates versions). There is no rule for abandoned uploads: Azure
# garbage-collects uncommitted blocks on its own schedule, and lifecycle
# management has no action for them.
resource "azurerm_storage_management_policy" "this" {
  storage_account_id = azurerm_storage_account.this.id

  rule {
    name    = "expire-noncurrent-versions"
    enabled = true

    filters {
      blob_types = ["blockBlob"]
    }

    actions {
      version {
        delete_after_days_since_creation = 90
      }
    }
  }

  # Network Watcher rewrites the current flow log blob every minute, and
  # versioning keeps each prior copy. Drop those copies after a day; the
  # flow log's own retention deletes the current blobs.
  rule {
    name    = "expire-flow-log-versions"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["insights-logs-flowlogflowevent/"]
    }

    actions {
      version {
        delete_after_days_since_creation = 1
      }
    }
  }
}

# Read-only config share holding margince.yaml. Terraform creates the share;
# the operator writes the file once by hand (README.md step 4). 5 GiB is Azure
# Files' minimum share quota; the config file needs a fraction of it.
resource "azurerm_storage_share" "config" {
  name               = "${var.name_prefix}-config"
  storage_account_id = azurerm_storage_account.this.id
  quota              = 5
}

# Margince's filesystem attachment store (MARGINCE_BLOBSTORE_PATH), mounted
# read-write into api and worker (containerapps.tf). The app's native store
# speaks S3 only, so until an Azure Blob adapter exists this share is where
# attachments live; the blob container above stays unused.
resource "azurerm_storage_share" "attachments" {
  name               = "${var.name_prefix}-attachments"
  storage_account_id = azurerm_storage_account.this.id
  quota              = 100 # GiB; billed on use, not quota
}

# ---- Attachments backup ---------------------------------------------------------
# Daily snapshot-based backup of the attachments and redis shares, kept 30 days
# in a Recovery Services vault. Soft delete above covers a deleted share; this
# covers deleted or overwritten files inside it.
resource "azurerm_recovery_services_vault" "this" {
  name                = "${local.global_prefix}-rsv"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard"
  # Soft delete is always on for Recovery Services vaults.
  tags = merge(local.common_tags, { Name = "${var.name_prefix}-rsv", Component = "storage" })
}

resource "azurerm_backup_policy_file_share" "daily" {
  name                = "${var.name_prefix}-attachments-daily"
  resource_group_name = azurerm_resource_group.this.name
  recovery_vault_name = azurerm_recovery_services_vault.this.name
  timezone            = "UTC"

  backup {
    frequency = "Daily"
    time      = "02:00"
  }

  retention_daily {
    count = 30
  }
}

resource "azurerm_backup_container_storage_account" "this" {
  resource_group_name = azurerm_resource_group.this.name
  recovery_vault_name = azurerm_recovery_services_vault.this.name
  storage_account_id  = azurerm_storage_account.this.id
}

resource "azurerm_backup_protected_file_share" "redis" {
  resource_group_name       = azurerm_resource_group.this.name
  recovery_vault_name       = azurerm_recovery_services_vault.this.name
  source_storage_account_id = azurerm_backup_container_storage_account.this.storage_account_id
  source_file_share_name    = azurerm_storage_share.redis.name
  backup_policy_id          = azurerm_backup_policy_file_share.daily.id
}

resource "azurerm_backup_protected_file_share" "attachments" {
  resource_group_name       = azurerm_resource_group.this.name
  recovery_vault_name       = azurerm_recovery_services_vault.this.name
  source_storage_account_id = azurerm_backup_container_storage_account.this.storage_account_id
  source_file_share_name    = azurerm_storage_share.attachments.name
  backup_policy_id          = azurerm_backup_policy_file_share.daily.id
}

# ---- Audit logs -----------------------------------------------------------------
# Reads, writes and deletes on the file shares, kept 90 days in Log
# Analytics.
resource "azurerm_monitor_diagnostic_setting" "files" {
  name                       = "${var.name_prefix}-files-audit"
  target_resource_id         = "${azurerm_storage_account.this.id}/fileServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "StorageRead"
  }
  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }
}
