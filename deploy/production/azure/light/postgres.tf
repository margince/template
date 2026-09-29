# Postgres Flexible Server, cheapest Burstable size, reachable only inside the
# VNet (delegated subnet + private DNS zone). "pgadmin" is the server's admin
# login, used once by the VM to run scripts/deploy/db-bootstrap.sql, which
# creates the margince database and the margince_owner (migrations) and
# margince_app (runtime) roles.

resource "random_password" "postgres_admin" {
  length  = 32
  special = false
}

# special = false keeps the passwords URL-safe, so the VM can place them in a
# DSN without encoding.
resource "random_password" "margince_owner" {
  length  = 32
  special = false
}

resource "random_password" "margince_app" {
  length  = 32
  special = false
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.name_prefix}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.common_tags
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

  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  administrator_login    = "pgadmin"
  administrator_password = random_password.postgres_admin.result

  sku_name                     = var.db_sku_name
  storage_mb                   = var.db_storage_mb
  auto_grow_enabled            = true # grows storage before it fills up
  backup_retention_days        = var.db_backup_retention_days
  geo_redundant_backup_enabled = false

  tags = local.common_tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  lifecycle {
    # Changing db_version, vnet_cidr, name_prefix or resource_group_name
    # replaces the server, which deletes the database and its backups.
    # Remove this line on purpose to allow that.
    prevent_destroy = true
    # Azure picks the zone; auto-grow raises storage (and its tier).
    ignore_changes = [zone, storage_mb, storage_tier]
  }
}

# Postgres Flexible Server refuses CREATE EXTENSION for anything not on this
# allow-list, even for the admin login. These are the extensions
# db-bootstrap.sql installs.
resource "azurerm_postgresql_flexible_server_configuration" "azure_extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "VECTOR,UNACCENT,PG_TRGM,BTREE_GIST"
}

# The server refuses plaintext connections. Clients also verify the server
# certificate (sslmode=verify-full&sslrootcert=system in every DSN).
resource "azurerm_postgresql_flexible_server_configuration" "require_secure_transport" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "ON"

  depends_on = [azurerm_postgresql_flexible_server_configuration.azure_extensions]
}

# Azure applies one configuration change at a time, so these follow each
# other.
resource "azurerm_postgresql_flexible_server_configuration" "ssl_min_protocol_version" {
  name      = "ssl_min_protocol_version"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "TLSv1.2"

  depends_on = [azurerm_postgresql_flexible_server_configuration.require_secure_transport]
}

# Temporarily throttles a client address after repeated failed logins.
resource "azurerm_postgresql_flexible_server_configuration" "connection_throttle" {
  name      = "connection_throttle.enable"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"

  depends_on = [azurerm_postgresql_flexible_server_configuration.ssl_min_protocol_version]
}
