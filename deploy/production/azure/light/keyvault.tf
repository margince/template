# Key Vault (standard, RBAC) holds the two values that make deploy needs from
# the operator and that Terraform knows: the Entra client secret and the
# license. make deploy reads them from its own environment; the secret_exports
# output prints the commands that fill it. The VM never reads the vault.
# The host adapter generates every other secret on the server
# (docs/deploy.md Section 5.6).

data "azurerm_client_config" "current" {}

locals {
  # The operator addresses. Key Vault takes a single address, not a /32 range.
  key_vault_ip_rules = distinct([for c in var.ssh_allowed_cidrs : trimsuffix(c, "/32")])

  license_set = nonsensitive(length(var.license_token) > 0)

  # Key Vault secret name => value. Key Vault rejects an empty value, so the
  # license secret exists only when license_token is set.
  kv_secrets = merge(
    { "margince-entra-client-secret" = local.entra_client_secret },
    local.license_set ? { "margince-license" = var.license_token } : {},
  )
}

resource "azurerm_key_vault" "this" {
  name                       = "${local.global_prefix}-kv" # at most 24 characters
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

  # Closed except for the operator addresses. Terraform writes the secrets
  # and make deploy reads them through the data plane.
  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
    ip_rules       = local.key_vault_ip_rules
  }

  tags = local.common_tags
}

# RBAC mode grants nobody data-plane access by default, including the
# identity that runs Terraform and writes the secrets below.
resource "azurerm_role_assignment" "terraform_kv_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "this" {
  for_each     = toset(keys(local.kv_secrets))
  name         = each.key
  value        = local.kv_secrets[each.key]
  key_vault_id = azurerm_key_vault.this.id
  tags         = local.common_tags

  # Key Vault raises SecretNearExpiry 30 days before the Entra secret ends.
  expiration_date = each.key == "margince-entra-client-secret" ? azuread_application_password.margince.end_date : null

  depends_on = [azurerm_role_assignment.terraform_kv_admin]
}
