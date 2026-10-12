# One customer-managed key for the data this stack stores at rest: the
# Storage Account and Postgres Flexible Server reference
# azurerm_key_vault_key.data below. One key is enough because the per-consumer
# RBAC grants are already the blast-radius boundary. Redis keeps its data on
# the storage account's redis share, so the same key covers it.
#
# rbac_authorization_enabled = true (not vault access policies): every other
# access control in this stack is Azure RBAC role assignments (identity.tf).
# Access policies would be a second permission model to keep in step.
#
# purge_protection_enabled = true + soft_delete_retention_days = 90 (the
# maximum): a deleted key or vault stays recoverable for 90 days. Purge
# protection can never be disabled once enabled, so the ceiling was chosen
# up front. versions.tf's provider `features` block turns off Terraform's
# destroy-time purge to match.
resource "azurerm_key_vault" "this" {
  name                       = "${local.global_prefix}-kv" # <= 24 characters
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "premium" # premium: HSM-backed keys, required for the CMK key type below
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 90
  # Enabled, with the firewall below denying everything except
  # operator_ip_allowlist and trusted Azure services. With an empty allowlist
  # nothing reaches it from the internet. Not disabled: Storage and Postgres
  # unwrap their customer-managed keys through the AzureServices bypass, and
  # a disabled public endpoint can cut that path off and take both down.
  public_network_access_enabled = true

  network_acls {
    # AzureServices bypass, not None: Storage/Postgres's own
    # customer_managed_key wiring calls Key Vault AS a trusted Azure service on
    # the consuming resource's behalf, over Azure's private backbone — not
    # through this stack's own private endpoint (privateendpoints.tf's own
    # Key Vault entry is for THIS stack's operators/Container Apps reading
    # secrets, a different caller than the CMK-consuming services themselves).
    bypass         = "AzureServices"
    default_action = "Deny"
    ip_rules       = var.operator_ip_allowlist
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-kv", Component = "security" })
}

# RBAC-authorization mode delegates EVERY data-plane action — including
# creating the key and secrets below — to Azure RBAC, with no default grant
# to whoever is running `terraform apply` itself (unlike the legacy
# access-policy model, which the resource above deliberately does not use).
# Without this, every azurerm_key_vault_key/azurerm_key_vault_secret resource
# in this stack fails Forbidden the moment it tries to write. Role
# assignments can take a short time to propagate — a fresh `terraform apply`
# immediately after this grant lands may need one retry.
#
# key_vault_admin_principal_ids names who gets the grant (ideally one Entra
# group holding every operator and the CI identity). Empty, it falls back to
# the identity running this apply, which ties the vault to one person: a
# second operator's apply would replace the grant and lock the first out.
locals {
  key_vault_admin_principal_ids = toset(
    length(var.key_vault_admin_principal_ids) > 0
    ? var.key_vault_admin_principal_ids
    : [data.azurerm_client_config.current.object_id]
  )
}

resource "azurerm_role_assignment" "terraform_key_vault_administrator" {
  for_each             = local.key_vault_admin_principal_ids
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = each.value
}

resource "azurerm_key_vault_key" "data" {
  name         = "${var.name_prefix}-data"
  key_vault_id = azurerm_key_vault.this.id
  # RSA, not EC: both consumers of this key (Storage Account, Postgres
  # Flexible Server) require an RSA key for envelope encryption — none of them accept an EC key.
  key_type = "RSA-HSM" # premium SKU: HSM-protected
  key_size = 2048

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  rotation_policy {
    expire_after         = "P2Y"
    notify_before_expiry = "P30D"
    automatic {
      time_before_expiry = "P30D"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-data", Component = "security" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

# Every secret read, key operation and permission change, kept 90 days in
# Log Analytics.
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "${var.name_prefix}-kv-audit"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "AuditEvent"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
