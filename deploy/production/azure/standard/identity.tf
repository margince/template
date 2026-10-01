# User-assigned managed identities and the RBAC role assignments that give
# each one only what it needs.
#
# Container Apps uses one identity per app for its Key Vault secret
# references (containerapps.tf's `secret` blocks). Azure Files
# mounts (containerapps.tf's environment storage) authenticate with the
# storage account key, not an identity, so no storage-mount role is granted.

resource "azurerm_user_assigned_identity" "data_cmk" {
  # Shared by the Storage Account (storage.tf) and Postgres Flexible Server
  # (postgres.tf) customer_managed_key blocks. One key, one identity: both
  # only wrap/unwrap under this stack's single data key.
  name                = "${var.name_prefix}-data-cmk"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-data-cmk", Component = "security" })
}

resource "azurerm_role_assignment" "data_cmk_key_vault_crypto_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.data_cmk.principal_id
}

# ---- api and worker: one identity each ---------------------------------------
# Each role reads only the Key Vault secrets its process uses
# (containerapps.tf, local.api_secrets / local.worker_secrets): Key Vault
# Secrets User is granted per secret, never on the whole vault. The api app's
# identity is also available to its edge (nginx) container, since Container
# Apps identities belong to the app; per-secret scoping is what limits that.

resource "azurerm_user_assigned_identity" "api" {
  name                = "${var.name_prefix}-api"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-api", Component = "security" })
}

resource "azurerm_user_assigned_identity" "worker" {
  name                = "${var.name_prefix}-worker"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-worker", Component = "security" })
}

resource "azurerm_role_assignment" "api_secret" {
  for_each             = local.api_secrets
  scope                = each.value.id.resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.api.principal_id
}

resource "azurerm_role_assignment" "worker_secret" {
  for_each             = local.worker_secrets
  scope                = each.value.id.resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.worker.principal_id
}

resource "azurerm_role_assignment" "api_source_registry_password" {
  count                = local.source_registry_credentials ? 1 : 0
  scope                = azurerm_key_vault_secret.source_registry_password[0].resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.api.principal_id
}

resource "azurerm_role_assignment" "worker_source_registry_password" {
  count                = local.source_registry_credentials ? 1 : 0
  scope                = azurerm_key_vault_secret.source_registry_password[0].resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.worker.principal_id
}

# There is no separate web app: the SPA is served by the edge container inside
# the api app (containerapps.tf), which pulls the web image with the api
# app's settings.

# ---- dataverse: Margince's server-to-server identity in Dataverse --------------
# Attached to api and worker. It holds no Azure role at all: its only use is
# as a Dataverse APPLICATION USER, which a Power Platform admin creates by hand
# from the dataverse_identity_client_id output, with a custom security role
# limited to the tables Margince syncs (README.md). No secret exists for it,
# and application users need no Dataverse licence.
#
# Nothing in Margince calls Dataverse yet (the overlay mode's `dynamics`
# incumbent is reserved but not implemented, docs/explanation/
# overlay-augmentation.md); the identity is provisioned now so the Dataverse
# side can be set up and reviewed ahead of that adapter.
resource "azurerm_user_assigned_identity" "dataverse" {
  name                = "${var.name_prefix}-dataverse"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-dataverse", Component = "security" })
}
