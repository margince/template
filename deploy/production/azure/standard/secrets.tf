# One Key Vault secret per credential, all in this stack's vault
# (keyvault.tf). There are no blobstore access keys to store: Margince has no
# Azure Blob adapter yet (see storage.tf's top comment). The vault's own
# encryption at rest is Microsoft-managed; Key Vault does not support a
# customer-managed key for its own storage.

resource "random_id" "keyvault_root_key" {
  byte_length = 32

  # Seals data already written by the app; regenerating it would lock the
  # installation out of its own vault.
  lifecycle {
    prevent_destroy = true
  }
}

resource "random_id" "webhook_key" {
  byte_length = 32

  # Seals data already written by the app; regenerating it would lock the
  # installation out of its own vault.
  lifecycle {
    prevent_destroy = true
  }
}

resource "random_id" "connector_state_key" {
  byte_length = 32

  # Seals data already written by the app; regenerating it would lock the
  # installation out of its own vault.
  lifecycle {
    prevent_destroy = true
  }
}

locals {
  # Flexible Server's TLS certificate chains to DigiCert Global Root G2/CA,
  # a public root most client trust stores already carry, so
  # sslmode=verify-full works without an sslrootcert parameter or a
  # downloaded CA bundle.
  db_host   = azurerm_postgresql_flexible_server.this.fqdn
  owner_dsn = "postgres://margince_owner:${urlencode(random_password.margince_owner.result)}@${local.db_host}:5432/margince?sslmode=verify-full"
  app_dsn   = "postgres://margince_app:${urlencode(random_password.margince_app.result)}@${local.db_host}:5432/margince?sslmode=verify-full"
}

resource "azurerm_key_vault_secret" "owner_dsn" {
  name         = "margince-owner-dsn"
  value        = local.owner_dsn
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-owner-dsn", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

resource "azurerm_key_vault_secret" "app_dsn" {
  name         = "margince-dsn"
  value        = local.app_dsn
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-app-dsn", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

resource "azurerm_key_vault_secret" "redis_password" {
  name         = "margince-redis-password"
  value        = random_password.redis.result
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-redis-password", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

resource "azurerm_key_vault_secret" "keyvault_root_key" {
  name         = "margince-keyvault-root-key"
  value        = random_id.keyvault_root_key.b64_std
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-keyvault-root-key", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_key_vault_secret" "webhook_key" {
  name         = "margince-webhook-key"
  value        = random_id.webhook_key.b64_std
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-webhook-key", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_key_vault_secret" "connector_state_key" {
  name         = "margince-connector-state-key"
  value        = random_id.connector_state_key.b64_std
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-connector-state-key", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_key_vault_secret" "admin_password" {
  name         = "margince-admin-password"
  value        = var.admin_bootstrap_password
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-admin-password", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

# license_token is required (variables.tf): a production installation
# refuses to boot without a licence (backend/internal/compose/license.go).
resource "azurerm_key_vault_secret" "license" {
  name         = "margince-license"
  value        = var.license_token
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-license", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

# ---- Outlook push notifications and metrics ------------------------------------

# Shared secret Microsoft Graph echoes on every change notification. api checks
# it (MARGINCE_GRAPH_PUSH_TOKEN); worker registers subscriptions pointing at
# the notification URL below (MARGINCE_GRAPH_NOTIFICATION_URL). With both set,
# Outlook capture is pushed instead of polled.
resource "random_password" "graph_push_token" {
  length  = 40
  special = false
}

resource "azurerm_key_vault_secret" "graph_push_token" {
  name         = "margince-graph-push-token"
  value        = random_password.graph_push_token.result
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-graph-push-token", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

resource "azurerm_key_vault_secret" "graph_notification_url" {
  name         = "margince-graph-notification-url"
  value        = "${var.public_base_url}/webhooks/graph?token=${random_password.graph_push_token.result}"
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-graph-notification-url", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

# Bearer token for cmd/api's /metrics (MARGINCE_METRICS_TOKEN). The edge
# returns 404 for /metrics anyway; this protects it inside the environment.
resource "random_password" "metrics_token" {
  length  = 40
  special = false
}

resource "azurerm_key_vault_secret" "metrics_token" {
  name         = "margince-metrics-token"
  value        = random_password.metrics_token.result
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-metrics-token", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}
