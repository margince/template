# Key Vault (standard SKU, RBAC) holding every generated secret. The VM's
# managed identity reads them at service start (margince-fetch-secrets) into
# an environment file only root and the service user can read.

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "this" {
  name                       = "${local.global_prefix}-kv" # at most 24 characters
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  # The vault holds the keys that seal Margince's data (keyvault root key,
  # webhook and connector-state keys). Purge protection keeps a deleted vault
  # or secret recoverable for 90 days, even by an administrator. It cannot be
  # turned off again; the name's random suffix means a rebuilt stack never
  # collides with a soft-deleted vault.
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

  # Firewall closed except for the VM (it reaches the vault from its public
  # IP) and the operators running Terraform, which writes and refreshes the
  # secrets through the data plane.
  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
    ip_rules       = distinct(concat(var.operator_ip_allowlist, [azurerm_public_ip.vm.ip_address]))
  }

  tags = local.common_tags
}

# RBAC mode grants nobody data-plane access by default, including the identity
# running Terraform, which writes the secrets below.
resource "azurerm_role_assignment" "terraform_kv_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "vm_kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.this.identity[0].principal_id
}

# ---- Generated values -----------------------------------------------------------

# These three seal data the app writes; regenerating one would lock the
# installation out of its own data.
resource "random_id" "keyvault_root_key" {
  byte_length = 32
  lifecycle {
    prevent_destroy = true
  }
}

resource "random_id" "webhook_key" {
  byte_length = 32
  lifecycle {
    prevent_destroy = true
  }
}

resource "random_id" "connector_state_key" {
  byte_length = 32
  lifecycle {
    prevent_destroy = true
  }
}

resource "random_password" "admin_bootstrap" {
  length  = 24
  special = false
}

resource "random_password" "metrics_token" {
  length  = 40
  special = false
}

# Microsoft Graph echoes this on every change notification (api checks it);
# the worker registers subscriptions pointing at the notification URL.
resource "random_password" "graph_push_token" {
  length  = 40
  special = false
}

locals {
  # Key Vault secret name => value. The VM reads the names listed in
  # local.secret_env (vm.tf); Postgres admin and role passwords are read by the
  # database bootstrap only.
  kv_secrets = merge(
    {
      "postgres-admin-password"      = random_password.postgres_admin.result
      "margince-owner-password"      = random_password.margince_owner.result
      "margince-app-password"        = random_password.margince_app.result
      "margince-keyvault-root-key"   = random_id.keyvault_root_key.b64_std
      "margince-webhook-key"         = random_id.webhook_key.b64_std
      "margince-connector-state-key" = random_id.connector_state_key.b64_std
      "margince-admin-password"      = random_password.admin_bootstrap.result
      "margince-metrics-token"       = random_password.metrics_token.result
      "margince-graph-push-token"    = random_password.graph_push_token.result
      "margince-entra-client-secret" = local.entra_client_secret
    },
    # Key Vault rejects empty values; an unlicensed development install simply
    # has no licence secret.
    nonsensitive(length(var.license_token) > 0) ? { "margince-license" = var.license_token } : {},
  )
}

resource "azurerm_key_vault_secret" "this" {
  for_each     = toset(keys(local.kv_secrets))
  name         = each.key
  value        = local.kv_secrets[each.key]
  key_vault_id = azurerm_key_vault.this.id
  tags         = local.common_tags

  # Key Vault raises SecretNearExpiry 30 days ahead of the Entra secret's end.
  expiration_date = each.key == "margince-entra-client-secret" && var.create_entra_app ? azuread_application_password.margince[0].end_date : null

  depends_on = [azurerm_role_assignment.terraform_kv_admin, terraform_data.posture]
}

# A production installation refuses to boot without a licence; fail the plan
# instead of the first boot.
resource "terraform_data" "posture" {
  lifecycle {
    precondition {
      condition     = var.environment_posture == "development" || length(var.license_token) > 0
      error_message = "A production installation needs license_token (or set environment_posture = \"development\" for a test install)."
    }
  }
}
