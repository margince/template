# One SSM Parameter Store SecureString per credential, under
# "/<name_prefix>/...". Standard tier (free, 4 KB value limit) and the
# AWS-managed alias/aws/ssm key (free) rather than Secrets Manager
# ($0.40/secret/month) or a customer CMK; this stack has neither (see
# rds.tf/s3.tf's own notes on that tradeoff). Each parameter maps to one env
# var a given instance's own user-data fetches at boot (ec2.tf).
#
# The aws/ssm key's own key policy already lets any principal in this
# account decrypt THROUGH SSM, so iam.tf needs no kms:Decrypt grant; what
# gates reading a value is the ssm:GetParameter* permission alone. That is
# also why iam.tf carries explicit Denies: AmazonSSMManagedInstanceCore
# grants ssm:GetParameter/GetParameters on "*".

# redis's AUTH token (requirepass) (no ElastiCache here - network.tf/ec2.tf's own notes
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
  # verify-full, not require - same reasoning as the full stack: require
  # alone encrypts the bytes but never checks the server's certificate or
  # hostname. sslrootcert points at the RDS CA bundle each instance's own
  # user-data downloads onto its local disk (templates/user_data-app.sh.tpl,
  # user_data-worker.sh.tpl), the same path the full stack mounts via EFS.
  owner_dsn = "postgres://margince_owner:${urlencode(random_password.margince_owner.result)}@${local.db_host}:${local.db_port}/margince?sslmode=verify-full&sslrootcert=/app/config/rds-ca-bundle.pem"
  app_dsn   = "postgres://margince_app:${urlencode(random_password.margince_app.result)}@${local.db_host}:${local.db_port}/margince?sslmode=verify-full&sslrootcert=/app/config/rds-ca-bundle.pem"

  # No ElastiCache - redis runs in a Docker container on the app instance
  # itself (ec2.tf). Its private IP, not a managed endpoint, is what worker (a
  # separate instance) and api both use to reach it.
  redis_host = local.app_private_ip

  # SSM rejects an empty parameter value, and an empty license means "run
  # unlicensed", so the license parameter only exists when a token is set;
  # the app's user-data writes MARGINCE_LICENSE= itself otherwise.
  # nonsensitive() exposes only whether the token is empty, never its value.
  license_set = nonsensitive(var.license_token != "")

  # Metadata only (no values), so it can drive for_each. `readers` is the
  # per-role least-privilege list: iam.tf allows exactly these and denies
  # the rest, ec2.tf fetches exactly these into that role's /.env. An empty
  # `env` / `readers` means humans only (read via the CLI, see README).
  secret_parameters = merge(
    {
      owner_dsn = {
        name        = "margince-owner-dsn"
        env         = "MARGINCE_OWNER_DSN"
        readers     = ["app"]
        description = "MARGINCE_OWNER_DSN: margince_owner (DDL/migrations) connection string."
      }
      app_dsn = {
        name        = "margince-dsn"
        env         = "MARGINCE_DSN"
        readers     = ["app", "worker"]
        description = "MARGINCE_DSN: margince_app (runtime DML) connection string."
      }
      redis_password = {
        name        = "margince-redis-password"
        env         = "MARGINCE_REDIS_PASSWORD"
        readers     = ["app", "worker"]
        description = "MARGINCE_REDIS_PASSWORD: AUTH token for the redis container on the app EC2 instance (not ElastiCache)."
      }
      keyvault_root_key = {
        name        = "margince-keyvault-root-key"
        env         = "MARGINCE_KEYVAULT_ROOT_KEY"
        readers     = ["app", "worker"]
        description = "MARGINCE_KEYVAULT_ROOT_KEY: root key for the encrypted-field keyvault."
      }
      webhook_key = {
        name        = "margince-webhook-key"
        env         = "MARGINCE_WEBHOOK_KEY"
        readers     = ["app", "worker"]
        description = "MARGINCE_WEBHOOK_KEY: HMAC key verifying inbound webhook signatures."
      }
      connector_state_key = {
        name        = "margince-connector-state-key"
        env         = "MARGINCE_CONNECTOR_STATE_KEY"
        readers     = ["app", "worker"]
        description = "MARGINCE_CONNECTOR_STATE_KEY: encrypts stored OAuth connector state."
      }
      admin_password = {
        name        = "margince-admin-password"
        env         = "MARGINCE_ADMIN_PASSWORD"
        readers     = ["app"]
        description = "MARGINCE_ADMIN_PASSWORD: first-boot bootstrap admin password; rotate/remove per docs/deployment.md once the organization exists."
      }
      blobstore_access_key = {
        name        = "margince-blobstore-access-key"
        env         = "MARGINCE_BLOBSTORE_ACCESS_KEY"
        readers     = ["app", "worker"]
        description = "MARGINCE_BLOBSTORE_ACCESS_KEY: the blobstore IAM user access key ID."
      }
      blobstore_secret_key = {
        name        = "margince-blobstore-secret-key"
        env         = "MARGINCE_BLOBSTORE_SECRET_KEY"
        readers     = ["app", "worker"]
        description = "MARGINCE_BLOBSTORE_SECRET_KEY: the blobstore IAM user secret access key."
      }
      rds_master_password = {
        name        = "rds-master-password"
        env         = ""
        readers     = []
        description = "RDS master user (dbadmin) password. Humans only (db-bootstrap.sql); no instance role can read it."
      }
    },
    local.license_set ? {
      license = {
        name        = "margince-license"
        env         = "MARGINCE_LICENSE"
        readers     = ["app"]
        description = "MARGINCE_LICENSE: production license token."
      }
    } : {},
  )

  secret_values = {
    owner_dsn            = local.owner_dsn
    app_dsn              = local.app_dsn
    redis_password       = random_password.redis_auth.result
    keyvault_root_key    = random_id.keyvault_root_key.b64_std
    webhook_key          = random_id.webhook_key.b64_std
    connector_state_key  = random_id.connector_state_key.b64_std
    admin_password       = var.admin_bootstrap_password
    license              = var.license_token
    blobstore_access_key = aws_iam_access_key.blobstore.id
    blobstore_secret_key = aws_iam_access_key.blobstore.secret
    rds_master_password  = random_password.rds_master.result
  }
}

resource "aws_ssm_parameter" "secret" {
  for_each = local.secret_parameters

  name        = "/${var.name_prefix}/${each.value.name}"
  description = each.value.description
  type        = "SecureString"
  tier        = "Standard"
  key_id      = "alias/aws/ssm"
  value       = local.secret_values[each.key]

  tags = { Name = "${var.name_prefix}-${each.value.name}", Component = "secrets" }
}
