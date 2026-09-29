# One SSM Parameter Store SecureString per credential, so each maps to exactly
# one ECS task-definition "secrets" entry (a single valueFrom) rather than
# requiring every consumer to parse a shared JSON blob.
#
# Parameter Store rather than Secrets Manager: every value here is a static
# string well under the Standard tier's 4 KB limit, none of them uses Secrets
# Manager's managed rotation (see README "Deliberately not done"), and
# Standard-tier parameters carry no per-secret monthly charge. Every
# parameter is sealed under the stack's CMK (kms.tf), not the aws/ssm default
# key; the ECS execution role's KMS grant (iam.tf) is what lets ECS decrypt
# them at task start.
#
# Naming: "/<name_prefix>/<credential>", one hierarchy per stack, so an IAM
# policy or an operator can address the whole set by path.
#
# SSM refuses an empty Value (PutParameter enforces a minimum length of 1),
# which is why the license parameter below is conditional rather than always
# present the way the old Secrets Manager secret was.

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
  # verify-full, not require: pgx v5 treats sslmode=require as "encrypt the
  # bytes" only; it does not check the server's certificate or hostname, so
  # a network-path attacker could still present themselves as the RDS
  # endpoint and pgx would accept it. verify-full is the mode that actually
  # authenticates the server, and it needs a CA bundle to check the
  # certificate against: sslrootcert points at the RDS global bundle an
  # operator places on the same EFS config mount margince.yaml already lives
  # on (this stack's README has the exact command). The server-side backstop
  # is still aws_db_parameter_group.this's rds.force_ssl (rds.tf); this is
  # the client-side half that makes "encrypted" also mean "to the right
  # server".
  owner_dsn  = "postgres://margince_owner:${urlencode(random_password.margince_owner.result)}@${local.db_host}:${local.db_port}/margince?sslmode=verify-full&sslrootcert=/app/config/rds-ca-bundle.pem"
  app_dsn    = "postgres://margince_app:${urlencode(random_password.margince_app.result)}@${local.db_host}:${local.db_port}/margince?sslmode=verify-full&sslrootcert=/app/config/rds-ca-bundle.pem"
  redis_host = aws_elasticache_replication_group.this.primary_endpoint_address

  ssm_prefix = "/${var.name_prefix}"
  # nonsensitive: whether a token is set is not itself secret, and count
  # refuses a sensitive value.
  has_license = nonsensitive(var.license_token != "")
}

resource "aws_ssm_parameter" "owner_dsn" {
  name        = "${local.ssm_prefix}/owner-dsn"
  description = "MARGINCE_OWNER_DSN: margince_owner (DDL/migrations) connection string."
  type        = "SecureString"
  tier        = "Standard"
  key_id      = aws_kms_key.data.arn
  value       = local.owner_dsn
  tags        = { Name = "${var.name_prefix}-owner-dsn", Component = "secrets" }
}

resource "aws_ssm_parameter" "app_dsn" {
  name        = "${local.ssm_prefix}/dsn"
  description = "MARGINCE_DSN: margince_app (runtime DML) connection string."
  type        = "SecureString"
  tier        = "Standard"
  key_id      = aws_kms_key.data.arn
  value       = local.app_dsn
  tags        = { Name = "${var.name_prefix}-app-dsn", Component = "secrets" }
}

resource "aws_ssm_parameter" "redis_password" {
  name        = "${local.ssm_prefix}/redis-password"
  description = "MARGINCE_REDIS_PASSWORD: ElastiCache AUTH token."
  type        = "SecureString"
  tier        = "Standard"
  key_id      = aws_kms_key.data.arn
  value       = random_password.redis_auth.result
  tags        = { Name = "${var.name_prefix}-redis-password", Component = "secrets" }
}

resource "aws_ssm_parameter" "keyvault_root_key" {
  name        = "${local.ssm_prefix}/keyvault-root-key"
  description = "MARGINCE_KEYVAULT_ROOT_KEY: root key for the app encrypted-field keyvault."
  type        = "SecureString"
  tier        = "Standard"
  key_id      = aws_kms_key.data.arn
  value       = random_id.keyvault_root_key.b64_std
  tags        = { Name = "${var.name_prefix}-keyvault-root-key", Component = "secrets" }
}

resource "aws_ssm_parameter" "webhook_key" {
  name        = "${local.ssm_prefix}/webhook-key"
  description = "MARGINCE_WEBHOOK_KEY: HMAC key verifying inbound webhook signatures."
  type        = "SecureString"
  tier        = "Standard"
  key_id      = aws_kms_key.data.arn
  value       = random_id.webhook_key.b64_std
  tags        = { Name = "${var.name_prefix}-webhook-key", Component = "secrets" }
}

resource "aws_ssm_parameter" "connector_state_key" {
  name        = "${local.ssm_prefix}/connector-state-key"
  description = "MARGINCE_CONNECTOR_STATE_KEY: encrypts stored OAuth connector state."
  type        = "SecureString"
  tier        = "Standard"
  key_id      = aws_kms_key.data.arn
  value       = random_id.connector_state_key.b64_std
  tags        = { Name = "${var.name_prefix}-connector-state-key", Component = "secrets" }
}

# Seeded from var.admin_bootstrap_password once. ignore_changes on value so
# an operator can overwrite it with something inert after first boot (README
# step 5) without the next apply writing the bootstrap password back.
resource "aws_ssm_parameter" "admin_password" {
  name        = "${local.ssm_prefix}/admin-password"
  description = "MARGINCE_ADMIN_PASSWORD: first-boot bootstrap admin password; overwrite with an inert value once the organization exists."
  type        = "SecureString"
  tier        = "Standard"
  key_id      = aws_kms_key.data.arn
  value       = var.admin_bootstrap_password
  tags        = { Name = "${var.name_prefix}-admin-password", Component = "secrets" }

  lifecycle {
    ignore_changes = [value]
  }
}

# Only when a token is set: SSM cannot store an empty value, and an unset
# MARGINCE_LICENSE is the same "runs unlicensed" state an empty one was.
resource "aws_ssm_parameter" "license" {
  count       = local.has_license ? 1 : 0
  name        = "${local.ssm_prefix}/license"
  description = "MARGINCE_LICENSE: product license token."
  type        = "SecureString"
  tier        = "Standard"
  key_id      = aws_kms_key.data.arn
  value       = var.license_token
  tags        = { Name = "${var.name_prefix}-license", Component = "secrets" }
}

resource "aws_ssm_parameter" "blobstore_access_key" {
  name        = "${local.ssm_prefix}/blobstore-access-key"
  description = "MARGINCE_BLOBSTORE_ACCESS_KEY: the blobstore IAM user access key ID."
  type        = "SecureString"
  tier        = "Standard"
  key_id      = aws_kms_key.data.arn
  value       = aws_iam_access_key.blobstore.id
  tags        = { Name = "${var.name_prefix}-blobstore-access-key", Component = "secrets" }
}

resource "aws_ssm_parameter" "blobstore_secret_key" {
  name        = "${local.ssm_prefix}/blobstore-secret-key"
  description = "MARGINCE_BLOBSTORE_SECRET_KEY: the blobstore IAM user secret access key."
  type        = "SecureString"
  tier        = "Standard"
  key_id      = aws_kms_key.data.arn
  value       = aws_iam_access_key.blobstore.secret
  tags        = { Name = "${var.name_prefix}-blobstore-secret-key", Component = "secrets" }
}

# Operator-only: never referenced by a task definition, and no execution role
# can read it (iam.tf). Exists so README step 2 reads the RDS master password
# from SSM instead of scraping it out of Terraform state.
resource "aws_ssm_parameter" "rds_master_password" {
  name        = "${local.ssm_prefix}/rds-master-password"
  description = "RDS master user (dbadmin) password, for the one-time database bootstrap. Not exposed to any ECS task."
  type        = "SecureString"
  tier        = "Standard"
  key_id      = aws_kms_key.data.arn
  value       = random_password.rds_master.result
  tags        = { Name = "${var.name_prefix}-rds-master-password", Component = "secrets" }
}

locals {
  # env var name => parameter ARN, for everything api/worker receive. The one
  # list ecs.tf (task definition "secrets") and iam.tf (ssm:GetParameters
  # resources) both read, so the two can never disagree.
  task_ssm_parameters = merge(
    {
      MARGINCE_OWNER_DSN            = aws_ssm_parameter.owner_dsn.arn
      MARGINCE_DSN                  = aws_ssm_parameter.app_dsn.arn
      MARGINCE_REDIS_PASSWORD       = aws_ssm_parameter.redis_password.arn
      MARGINCE_KEYVAULT_ROOT_KEY    = aws_ssm_parameter.keyvault_root_key.arn
      MARGINCE_WEBHOOK_KEY          = aws_ssm_parameter.webhook_key.arn
      MARGINCE_CONNECTOR_STATE_KEY  = aws_ssm_parameter.connector_state_key.arn
      MARGINCE_ADMIN_PASSWORD       = aws_ssm_parameter.admin_password.arn
      MARGINCE_BLOBSTORE_ACCESS_KEY = aws_ssm_parameter.blobstore_access_key.arn
      MARGINCE_BLOBSTORE_SECRET_KEY = aws_ssm_parameter.blobstore_secret_key.arn
    },
    local.has_license ? { MARGINCE_LICENSE = aws_ssm_parameter.license[0].arn } : {},
  )
}
