# The server's admin login is a third credential, separate from the two DB
# roles scripts/deploy/db-bootstrap.sql creates (margince_owner, margince_app;
# see docs/deployment.md's "two-role database model" in the Margince
# repository). It is named "pgadmin" so it is never confused with either.
# Flexible Server's admin is not a true superuser but gets a broad privilege
# set (create role, create database, manage allow-listed extensions). That is
# based on Azure's documentation, not tested here: verify it on the actual
# server before relying on it beyond README.md's bootstrap step.
resource "random_password" "postgres_admin" {
  length  = 32
  special = false
}

resource "random_password" "margince_owner" {
  length  = 32
  special = false
}

resource "random_password" "margince_app" {
  length  = 32
  special = false
}

# ---- Private connectivity: delegated subnet, not a private endpoint ---------
# Postgres is the one data service without a private endpoint. It uses VNet
# integration instead: a delegated subnet (network.tf's
# azurerm_subnet.postgres) plus a private DNS zone, the provider's documented
# standard mode.
# Private endpoints for Flexible Server only exist in the more constrained
# "public access with private endpoint" networking mode.
resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.name_prefix}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-postgres", Component = "database" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "${var.name_prefix}-postgres"
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  resource_group_name   = azurerm_resource_group.this.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = "${local.global_prefix}-db"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  version             = var.db_version

  delegated_subnet_id = azurerm_subnet.postgres.id
  private_dns_zone_id = azurerm_private_dns_zone.postgres.id

  administrator_login    = "pgadmin"
  administrator_password = random_password.postgres_admin.result
  # Dual mode: Microsoft Entra sign-in is on (postgres_entra_admin_object_id
  # below adds an Entra administrator), and password sign-in stays on because
  # the app and db-bootstrap.sql use password roles.
  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = true
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  sku_name     = var.db_sku_name
  storage_mb   = var.db_storage_mb
  storage_tier = "P6"
  # Grows the disk before it fills up instead of the server going read-only.
  auto_grow_enabled = true

  backup_retention_days = var.db_backup_retention_days
  # Single-region by design (no multi-region or DR). Geo-redundant backup
  # would cost more and is left off.
  geo_redundant_backup_enabled = false

  dynamic "high_availability" {
    for_each = var.db_zone_redundant_ha ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }

  maintenance_window {
    day_of_week  = 1 # Monday, 04:30 UTC
    start_hour   = 4
    start_minute = 30
  }

  dynamic "identity" {
    for_each = var.postgres_customer_managed_key ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [azurerm_user_assigned_identity.data_cmk.id]
    }
  }

  dynamic "customer_managed_key" {
    for_each = var.postgres_customer_managed_key ? [1] : []
    content {
      key_vault_key_id                  = azurerm_key_vault_key.data.versionless_id
      primary_user_assigned_identity_id = azurerm_user_assigned_identity.data_cmk.id
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-db", Component = "database" })

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.postgres,
    azurerm_role_assignment.data_cmk_key_vault_crypto_user,
  ]

  lifecycle {
    precondition {
      condition     = !(var.db_zone_redundant_ha && startswith(var.db_sku_name, "B_"))
      error_message = "Zone-redundant HA needs a General Purpose or Memory Optimized SKU (e.g. GP_Standard_D2ds_v5), not Burstable."
    }
    # Azure picks the zones and swaps them on failover. Auto-grow raises the
    # size and the performance tier outside Terraform.
    ignore_changes = [zone, high_availability[0].standby_availability_zone, storage_mb, storage_tier]
  }

  # No final snapshot on delete: Flexible Server neither requires nor accepts
  # one. Recovery after deletion relies on the backup_retention_days
  # point-in-time-restore window.
  #
  # scripts/deploy/db-bootstrap.sql runs once, by hand, against this server as
  # "pgadmin" (README.md step 3). Flexible Server only creates a default
  # "postgres" database and has no argument to create another at provision
  # time, so the script's `CREATE DATABASE margince OWNER margince_owner`
  # branch runs here.
}

# Allow-lists the extensions migration 0001_baseline installs
# (db-bootstrap.sql). Flexible Server refuses `CREATE EXTENSION`, even for the
# admin login, for any extension not named in this server-level setting, and
# there is no SQL-side way to change it. Apply this before running
# db-bootstrap.sql; otherwise the script fails at the vector extension with a
# Postgres error, not a Terraform one.
resource "azurerm_postgresql_flexible_server_configuration" "azure_extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "VECTOR,UNACCENT,PG_TRGM,BTREE_GIST"
}

# Server refuses plaintext connections. sslmode=require only asks the client
# to encrypt; this makes the server reject a client that does not.
resource "azurerm_postgresql_flexible_server_configuration" "require_secure_transport" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "ON"
}

# Refuses TLS 1.0 and 1.1 handshakes.
resource "azurerm_postgresql_flexible_server_configuration" "ssl_min_protocol_version" {
  name      = "ssl_min_protocol_version"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "TLSv1.2"
}

# Temporarily blocks a client IP after repeated failed logins.
resource "azurerm_postgresql_flexible_server_configuration" "connection_throttle" {
  name      = "connection_throttle.enable"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

# Optional Microsoft Entra administrator (a user, group or service principal).
# It can create Entra-authenticated roles; the app keeps its password roles.
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "this" {
  count               = var.postgres_entra_admin_object_id != "" ? 1 : 0
  server_name         = azurerm_postgresql_flexible_server.this.name
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = var.postgres_entra_admin_object_id
  principal_name      = var.postgres_entra_admin_name
  principal_type      = var.postgres_entra_admin_type
}

# None of these four log_* settings default to on. Without them the
# PostgreSQLLogs export below ships an empty stream.
resource "azurerm_postgresql_flexible_server_configuration" "log_min_duration_statement" {
  name      = "log_min_duration_statement"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "1000"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_connections" {
  name      = "log_connections"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_disconnections" {
  name      = "log_disconnections"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_lock_waits" {
  name      = "log_lock_waits"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

# Azure Monitor collects Flexible Server metrics (cpu_percent,
# memory_percent, storage_percent, active_connections, ...) with no extra
# setup. This diagnostic setting adds the server logs, sent to the shared Log
# Analytics workspace (network.tf).
resource "azurerm_monitor_diagnostic_setting" "postgres" {
  name                       = "${var.name_prefix}-db"
  target_resource_id         = azurerm_postgresql_flexible_server.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "PostgreSQLLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
