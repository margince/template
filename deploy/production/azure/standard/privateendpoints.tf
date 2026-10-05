# Private endpoints for Key Vault and storage (blob and file): Container Apps,
# the jumpbox and the Application Gateway reach both only through these,
# since their firewalls deny the public internet (keyvault.tf, storage.tf).
#
# One shared subnet (network.tf's azurerm_subnet.private_endpoints), one
# private DNS zone per service, each zone linked to this stack's one VNet —
# the same "one boundary, not N" reasoning network.tf's own comment gives for
# why that subnet isn't split further.

resource "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-kv", Component = "network" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  name                  = "${var.name_prefix}-kv"
  private_dns_zone_name = azurerm_private_dns_zone.key_vault.name
  resource_group_name   = azurerm_resource_group.this.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "${var.name_prefix}-kv"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-kv", Component = "network" })

  private_service_connection {
    name                           = "${var.name_prefix}-kv"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "kv"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault.id]
  }
}

# One private endpoint for both blob and file sub-resources of the same
# storage account (storage.tf) — Azure documents this combination as
# supported on a single endpoint, unlike, say, blob+queue which need separate
# endpoints for unrelated reasons. Two DNS zones still apply (each
# sub-resource resolves through its own privatelink zone), so both are linked
# in the one private_dns_zone_group below.
resource "azurerm_private_dns_zone" "storage_blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-blob", Component = "network" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_blob" {
  name                  = "${var.name_prefix}-blob"
  private_dns_zone_name = azurerm_private_dns_zone.storage_blob.name
  resource_group_name   = azurerm_resource_group.this.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_private_dns_zone" "storage_file" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-file", Component = "network" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_file" {
  name                  = "${var.name_prefix}-file"
  private_dns_zone_name = azurerm_private_dns_zone.storage_file.name
  resource_group_name   = azurerm_resource_group.this.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

# One endpoint per storage sub-resource: Azure accepts a single group ID per
# private endpoint. `file` carries the config and attachments shares that
# Container Apps mount; `blob` serves the (currently unused) blob container.
resource "azurerm_private_endpoint" "storage" {
  for_each = {
    blob = azurerm_private_dns_zone.storage_blob.id
    file = azurerm_private_dns_zone.storage_file.id
  }
  name                = "${var.name_prefix}-storage-${each.key}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-storage-${each.key}", Component = "network" })

  private_service_connection {
    name                           = "${var.name_prefix}-storage-${each.key}"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "storage-${each.key}"
    private_dns_zone_ids = [each.value]
  }
}
