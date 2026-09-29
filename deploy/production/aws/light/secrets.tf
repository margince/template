# One Secrets Manager secret per credential, same shape as the full stack
# (../standard/secrets.tf) — each maps to one env var a given
# instance's own user-data fetches at boot (ec2.tf). Sealed under the
# default aws/secretsmanager key, not a customer CMK — this stack has none
# (see rds.tf/s3.tf's own notes on that tradeoff).

# valkey's AUTH token (no ElastiCache here — network.tf/ec2.tf's own notes
# on why this crosses a real network hop between the app and worker
# instances, unlike a loopback-only single-box design).
resource "random_password" "redis_auth" {
  length  = 32
  special = false
}

resource "random_id" "keyvault_root_key" {
  byte_length = 32
}

resource "random_id" "webhook_key" {
  byte_length = 32
}

resource "random_id" "connector_state_key" {
  byte_length = 32
}

locals {
  db_host = aws_db_instance.this.address
  db_port = aws_db_instance.this.port
  # verify-full, not require — same reasoning as the full stack: require
  # alone encrypts the bytes but never checks the server's certificate or
  # hostname. sslrootcert points at the RDS CA bundle each instance's own
  # user-data downloads onto its local disk (templates/user_data-app.sh.tpl,
  # user_data-worker.sh.tpl), the same path the full stack mounts via EFS.
  owner_dsn = "postgres://margince_owner:${urlencode(random_password.margince_owner.result)}@${local.db_host}:${local.db_port}/margince?sslmode=verify-full&sslrootcert=/app/config/rds-ca-bundle.pem"
  app_dsn   = "postgres://margince_app:${urlencode(random_password.margince_app.result)}@${local.db_host}:${local.db_port}/margince?sslmode=verify-full&sslrootcert=/app/config/rds-ca-bundle.pem"

  # No ElastiCache — valkey runs natively on the app instance itself
  # (ec2.tf). Its private IP, not a managed endpoint, is what worker (a
  # separate instance) and api both use to reach it.
  redis_host = local.app_private_ip
}

resource "aws_secretsmanager_secret" "owner_dsn" {
  name        = "${var.name_prefix}/margince-owner-dsn"
  description = "MARGINCE_OWNER_DSN — margince_owner (DDL/migrations) connection string."
  tags        = { Name = "${var.name_prefix}-owner-dsn", Component = "secrets" }
}
resource "aws_secretsmanager_secret_version" "owner_dsn" {
  secret_id     = aws_secretsmanager_secret.owner_dsn.id
  secret_string = local.owner_dsn
}

resource "aws_secretsmanager_secret" "app_dsn" {
  name        = "${var.name_prefix}/margince-dsn"
  description = "MARGINCE_DSN — margince_app (runtime DML) connection string."
  tags        = { Name = "${var.name_prefix}-app-dsn", Component = "secrets" }
}
resource "aws_secretsmanager_secret_version" "app_dsn" {
  secret_id     = aws_secretsmanager_secret.app_dsn.id
  secret_string = local.app_dsn
}

resource "aws_secretsmanager_secret" "redis_password" {
  name        = "${var.name_prefix}/margince-redis-password"
  description = "MARGINCE_REDIS_PASSWORD — AUTH token for the valkey instance running on the app EC2 instance (not ElastiCache)."
  tags        = { Name = "${var.name_prefix}-redis-password", Component = "secrets" }
}
resource "aws_secretsmanager_secret_version" "redis_password" {
  secret_id     = aws_secretsmanager_secret.redis_password.id
  secret_string = random_password.redis_auth.result
}

resource "aws_secretsmanager_secret" "keyvault_root_key" {
  name        = "${var.name_prefix}/margince-keyvault-root-key"
  description = "MARGINCE_KEYVAULT_ROOT_KEY — root key for the app's own encrypted-field keyvault."
  tags        = { Name = "${var.name_prefix}-keyvault-root-key", Component = "secrets" }
}
resource "aws_secretsmanager_secret_version" "keyvault_root_key" {
  secret_id     = aws_secretsmanager_secret.keyvault_root_key.id
  secret_string = random_id.keyvault_root_key.b64_std
}

resource "aws_secretsmanager_secret" "webhook_key" {
  name        = "${var.name_prefix}/margince-webhook-key"
  description = "MARGINCE_WEBHOOK_KEY — HMAC key verifying inbound webhook signatures."
  tags        = { Name = "${var.name_prefix}-webhook-key", Component = "secrets" }
}
resource "aws_secretsmanager_secret_version" "webhook_key" {
  secret_id     = aws_secretsmanager_secret.webhook_key.id
  secret_string = random_id.webhook_key.b64_std
}

resource "aws_secretsmanager_secret" "connector_state_key" {
  name        = "${var.name_prefix}/margince-connector-state-key"
  description = "MARGINCE_CONNECTOR_STATE_KEY — encrypts stored OAuth connector state."
  tags        = { Name = "${var.name_prefix}-connector-state-key", Component = "secrets" }
}
resource "aws_secretsmanager_secret_version" "connector_state_key" {
  secret_id     = aws_secretsmanager_secret.connector_state_key.id
  secret_string = random_id.connector_state_key.b64_std
}

resource "aws_secretsmanager_secret" "admin_password" {
  name        = "${var.name_prefix}/margince-admin-password"
  description = "MARGINCE_ADMIN_PASSWORD — first-boot bootstrap admin password; rotate/remove per the Margince repository's docs/deployment.md once the organization exists."
  tags        = { Name = "${var.name_prefix}-admin-password", Component = "secrets" }
}
resource "aws_secretsmanager_secret_version" "admin_password" {
  secret_id     = aws_secretsmanager_secret.admin_password.id
  secret_string = var.admin_bootstrap_password
}

resource "aws_secretsmanager_secret" "license" {
  name        = "${var.name_prefix}/margince-license"
  description = "MARGINCE_LICENSE — empty runs unlicensed; a production role refuses to boot on that."
  tags        = { Name = "${var.name_prefix}-license", Component = "secrets" }
}
resource "aws_secretsmanager_secret_version" "license" {
  secret_id     = aws_secretsmanager_secret.license.id
  secret_string = var.license_token
}

resource "aws_secretsmanager_secret" "blobstore_access_key" {
  name        = "${var.name_prefix}/margince-blobstore-access-key"
  description = "MARGINCE_BLOBSTORE_ACCESS_KEY — the blobstore IAM user's access key ID."
  tags        = { Name = "${var.name_prefix}-blobstore-access-key", Component = "secrets" }
}
resource "aws_secretsmanager_secret_version" "blobstore_access_key" {
  secret_id     = aws_secretsmanager_secret.blobstore_access_key.id
  secret_string = aws_iam_access_key.blobstore.id
}

resource "aws_secretsmanager_secret" "blobstore_secret_key" {
  name        = "${var.name_prefix}/margince-blobstore-secret-key"
  description = "MARGINCE_BLOBSTORE_SECRET_KEY — the blobstore IAM user's secret access key."
  tags        = { Name = "${var.name_prefix}-blobstore-secret-key", Component = "secrets" }
}
resource "aws_secretsmanager_secret_version" "blobstore_secret_key" {
  secret_id     = aws_secretsmanager_secret.blobstore_secret_key.id
  secret_string = aws_iam_access_key.blobstore.secret
}
