# ---- First-time setup, part of every apply ------------------------------------
# One Fargate task, run by Terraform before the services (terraform_data.setup
# below), does what an operator used to do from a bootstrap host:
#
#   prepare   core's api image: writes margince.yaml (the instance's
#             deploy/<env>/config/margince.yaml, the file the light stacks use)
#             and the RDS CA bundle onto the EFS config volume
#   database  the template's Postgres image: runs core's db-bootstrap.sql as
#             dbadmin through scripts/bootstrap-db.sh (the same file as the
#             Azure stack's: RDS's admin is not a superuser), after prepare
#             succeeded (core/docs/deployment.md, "Order of operations")
#
# The SQL is idempotent, so the task runs again whenever its definition changes
# (a new margince.yaml, a new core SQL, a new release image) and changes nothing
# else. scripts/run-setup.sh starts it with the AWS CLI and fails the apply
# unless both containers exit 0.

locals {
  # The Postgres image the template's host adapter pins
  # (scripts/deploy/host/compose.yaml), for its psql.
  setup_postgres_image = "pgvector/pgvector:pg16@sha256:1d533553fefe4f12e5d80c7b80622ba0c382abb5758856f52983d8789179f0fb"
  rds_ca_bundle_url    = "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
  margince_config_path = coalesce(var.margince_config_path, "${path.module}/../../config/margince.yaml")
  bootstrap_sql_path   = coalesce(var.bootstrap_sql_path, "${path.module}/../../../../core/scripts/deploy/db-bootstrap.sql")

  setup_ssm_parameters = {
    MARGINCE_OWNER_DSN  = aws_ssm_parameter.owner_dsn.arn
    MARGINCE_DSN        = aws_ssm_parameter.app_dsn.arn
    RDS_MASTER_PASSWORD = aws_ssm_parameter.rds_master_password.arn
  }

  setup_containers = [
    {
      name       = "prepare"
      image      = local.images.api
      essential  = false
      user       = "10001"
      entryPoint = ["sh", "-c"]
      command = [join("\n", [
        "set -eu",
        "printf '%s' \"$MARGINCE_CONFIG_B64\" | base64 -d > /config/margince.yaml.tmp",
        "mv /config/margince.yaml.tmp /config/margince.yaml",
        "wget -q -O /config/rds-ca-bundle.pem.tmp \"$RDS_CA_BUNDLE_URL\"",
        "mv /config/rds-ca-bundle.pem.tmp /config/rds-ca-bundle.pem",
        "echo 'setup: margince.yaml and the RDS CA bundle are on the config volume'",
      ])]
      environment = [
        { name = "MARGINCE_CONFIG_B64", value = filebase64(local.margince_config_path) },
        { name = "RDS_CA_BUNDLE_URL", value = local.rds_ca_bundle_url },
      ]
      mountPoints      = [{ sourceVolume = local.config_volume_name, containerPath = "/config", readOnly = false }]
      linuxParameters  = { capabilities = { drop = ["ALL"] } }
      logConfiguration = local.setup_log_configuration
    },
    {
      name       = "database"
      image      = local.setup_postgres_image
      essential  = true
      dependsOn  = [{ containerName = "prepare", condition = "SUCCESS" }]
      entryPoint = ["bash", "-c"]
      command = [join("\n", [
        "set -euo pipefail",
        "printf '%s' \"$BOOTSTRAP_SCRIPT_B64\" | base64 -d > /tmp/bootstrap-db.sh",
        "printf '%s' \"$BOOTSTRAP_SQL_B64\" | base64 -d > /tmp/db-bootstrap.sql",
        # The role passwords are alphanumeric (rds.tf), so the DSN holds them as is.
        "BOOTSTRAP_OWNER_PASSWORD=\"$(printf '%s' \"$MARGINCE_OWNER_DSN\" | sed -E 's#^[^:]+://[^:]+:([^@]+)@.*#\\1#')\"",
        "BOOTSTRAP_APP_PASSWORD=\"$(printf '%s' \"$MARGINCE_DSN\" | sed -E 's#^[^:]+://[^:]+:([^@]+)@.*#\\1#')\"",
        "export BOOTSTRAP_OWNER_PASSWORD BOOTSTRAP_APP_PASSWORD BOOTSTRAP_PG_ADMIN_PASSWORD=\"$RDS_MASTER_PASSWORD\"",
        "exec bash /tmp/bootstrap-db.sh /tmp/db-bootstrap.sql",
      ])]
      environment = [
        { name = "BOOTSTRAP_SCRIPT_B64", value = filebase64("${path.module}/scripts/bootstrap-db.sh") },
        { name = "BOOTSTRAP_SQL_B64", value = filebase64(local.bootstrap_sql_path) },
        { name = "BOOTSTRAP_PG_HOST", value = local.db_host },
        { name = "BOOTSTRAP_PG_ADMIN_USER", value = "dbadmin" },
        { name = "BOOTSTRAP_PGSSLROOTCERT", value = "/config/rds-ca-bundle.pem" },
      ]
      secrets = [
        for name in sort(keys(local.setup_ssm_parameters)) :
        { name = name, valueFrom = local.setup_ssm_parameters[name] }
      ]
      mountPoints      = [{ sourceVolume = local.config_volume_name, containerPath = "/config", readOnly = true }]
      linuxParameters  = { capabilities = { drop = ["ALL"] } }
      logConfiguration = local.setup_log_configuration
    },
  ]

  setup_log_configuration = {
    logDriver = "awslogs"
    options = {
      "awslogs-group"         = aws_cloudwatch_log_group.setup.name
      "awslogs-region"        = var.aws_region
      "awslogs-stream-prefix" = "setup"
    }
  }
}

resource "aws_cloudwatch_log_group" "setup" {
  name              = "/ecs/${var.name_prefix}/setup"
  retention_in_days = local.log_retention_days
  tags              = { Name = "${var.name_prefix}-setup-logs", Component = "observability" }
}

# The setup task's network identity. RDS, EFS and the interface endpoints admit
# it (network.tf, vpc-endpoints.tf); nothing admits traffic into it.
resource "aws_security_group" "ops" {
  name_prefix = "${var.name_prefix}-ops-"
  description = "One-off setup task: no ingress; egress for image pulls, the RDS CA bundle, RDS, EFS and the endpoints."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name_prefix}-ops", Component = "operations" }

  egress {
    description = "Image pulls and the RDS CA bundle over NAT, RDS, EFS, endpoints"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

# Execution role: reads the three parameters the database step needs and writes
# the setup log. The RDS master password is readable by this role only.
resource "aws_iam_role" "setup_execution" {
  name               = "${var.name_prefix}-setup-execution"
  description        = "ECS execution role for the one-off setup task; reads the owner and app DSNs and the RDS master password, writes the setup log."
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = { Name = "${var.name_prefix}-setup-execution", Component = "security" }
}

data "aws_iam_policy_document" "setup_execution" {
  statement {
    sid       = "ReadSetupParameters"
    actions   = ["ssm:GetParameters"]
    resources = sort(values(local.setup_ssm_parameters))
  }
  statement {
    sid       = "UseDataKey"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.data.arn]
  }
  statement {
    sid       = "WriteSetupLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.setup.arn}:*"]
  }
}

resource "aws_iam_role_policy" "setup_execution" {
  name   = "${var.name_prefix}-setup-execution"
  role   = aws_iam_role.setup_execution.id
  policy = data.aws_iam_policy_document.setup_execution.json
}

# Task role: mount and write the EFS config access point, nothing else.
resource "aws_iam_role" "setup_task" {
  name               = "${var.name_prefix}-setup-task"
  description        = "Task role for the one-off setup task; mounts and writes the EFS config access point."
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = { Name = "${var.name_prefix}-setup-task", Component = "security" }
}

data "aws_iam_policy_document" "setup_task" {
  statement {
    sid       = "MountAndWriteConfigVolume"
    actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
    resources = [aws_efs_file_system.config.arn]
    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"
      values   = [aws_efs_access_point.config.arn]
    }
  }
}

resource "aws_iam_role_policy" "setup_task" {
  name   = "${var.name_prefix}-setup-task"
  role   = aws_iam_role.setup_task.id
  policy = data.aws_iam_policy_document.setup_task.json
}

resource "aws_ecs_task_definition" "setup" {
  family                   = "${var.name_prefix}-setup"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.setup_execution.arn
  task_role_arn            = aws_iam_role.setup_task.arn

  runtime_platform {
    cpu_architecture        = var.cpu_architecture
    operating_system_family = "LINUX"
  }

  volume {
    name = local.config_volume_name
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.config.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.config.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode(local.setup_containers)
  tags                  = { Name = "${var.name_prefix}-setup", Component = "operations" }
}

# Runs the setup task once per new task definition revision, before the
# services start (their depends_on), and fails the apply if it fails.
resource "terraform_data" "setup" {
  triggers_replace = [aws_ecs_task_definition.setup.arn]

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/run-setup.sh"
    environment = {
      AWS_REGION      = var.aws_region
      CLUSTER         = aws_ecs_cluster.this.name
      TASK_DEFINITION = aws_ecs_task_definition.setup.arn
      SUBNETS         = join(",", aws_subnet.private[*].id)
      SECURITY_GROUP  = aws_security_group.ops.id
      LOG_GROUP       = aws_cloudwatch_log_group.setup.name
    }
  }

  depends_on = [
    aws_db_instance.this,
    aws_efs_mount_target.config,
    aws_iam_role_policy.setup_execution,
    aws_iam_role_policy.setup_task,
    aws_vpc_endpoint.interface,
    aws_nat_gateway.this,
  ]
}
