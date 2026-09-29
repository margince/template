# Three EC2 instance roles, one per compute role (edge/app/worker) — unlike
# the single shared role this stack used to carry, each is scoped to only
# the SSM parameters and S3 objects that role's own process actually reads. worker
# in particular drops owner_dsn/admin_password/license entirely: its
# entrypoint (scripts/deploy/worker-entrypoint.sh) runs no migrations and
# reads none of those.

resource "aws_cloudwatch_log_group" "edge" {
  name              = "/${var.name_prefix}/edge"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${var.name_prefix}-edge-logs", Component = "observability" }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.name_prefix}/app"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${var.name_prefix}-app-logs", Component = "observability" }
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/${var.name_prefix}/worker"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${var.name_prefix}-worker-logs", Component = "observability" }
}

# ec2.amazonaws.com's own AssumeRole is already scoped to instances launched
# in THIS account (the trust relationship is per-account by construction for
# EC2), so none of the three roles below need an aws:SourceAccount/SourceArn
# condition the way the full stack's ecs_assume does for the shared
# ecs-tasks.amazonaws.com principal.
locals {
  # Per-role SSM parameter ARNs from secrets.tf's `readers` lists. `allow`
  # is what that role's user-data fetches; `deny` is every other parameter
  # this stack owns (incl. rds_master_password, which no role reads). The
  # explicit Deny matters: AmazonSSMManagedInstanceCore, attached to every
  # role for Session Manager, grants ssm:GetParameter/GetParameters on "*",
  # and the aws/ssm key policy lets any account principal decrypt via SSM,
  # so without it worker could read owner_dsn/admin_password.
  #
  # No kms:Decrypt grant: the AWS-managed aws/ssm key authorizes decryption
  # through its own key policy (kms:ViaService = ssm.<region> +
  # kms:CallerAccount), which cannot be edited and needs no IAM allow.
  role_parameter_arns = {
    for role in ["edge", "app", "worker"] : role => {
      allow = [for k, v in local.secret_parameters : aws_ssm_parameter.secret[k].arn if contains(v.readers, role)]
      deny  = [for k, v in local.secret_parameters : aws_ssm_parameter.secret[k].arn if !contains(v.readers, role)]
    }
  }
  ssm_read_actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"]

  ec2_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ---- edge --------------------------------------------------------------------
# nginx + the built frontend. No application secrets at all: the frontend
# is static, nothing server-side here ever holds a credential.

resource "aws_iam_role" "edge" {
  name               = "${var.name_prefix}-edge"
  assume_role_policy = local.ec2_assume_role_policy
  tags               = { Name = "${var.name_prefix}-edge", Component = "security" }
}

resource "aws_iam_instance_profile" "edge" {
  name = "${var.name_prefix}-edge"
  role = aws_iam_role.edge.name
  tags = { Name = "${var.name_prefix}-edge", Component = "security" }
}

resource "aws_iam_role_policy_attachment" "edge_ssm" {
  role       = aws_iam_role.edge.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "edge_extra" {
  # AmazonSSMManagedInstanceCore allows ssm:GetParameter* on "*"; edge reads
  # no application secret, so every one of this stack's parameters is denied.
  statement {
    sid       = "DenyAllParameters"
    effect    = "Deny"
    actions   = local.ssm_read_actions
    resources = local.role_parameter_arns.edge.deny
  }
  statement {
    sid       = "DenyParameterBulkReads"
    effect    = "Deny"
    actions   = ["ssm:GetParametersByPath", "ssm:GetParameterHistory"]
    resources = ["*"]
  }
  # The shared source archive (build.tf) for this instance's own from-source
  # build, and its own built-frontend cache under binaries/ — read to skip a
  # rebuild if another boot already published it, write to publish this
  # boot's own build.
  statement {
    sid       = "ReadOwnSourceObject"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.blobstore.arn}/source/${var.image_tag}.zip"]
  }
  statement {
    sid       = "ReadWriteOwnBinaryCache"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.blobstore.arn}/binaries/edge-${var.image_tag}.tar.gz"]
  }
  statement {
    sid     = "WriteOwnLogs"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = [
      "${aws_cloudwatch_log_group.edge.arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "edge_extra" {
  name   = "${var.name_prefix}-edge-extra"
  role   = aws_iam_role.edge.id
  policy = data.aws_iam_policy_document.edge_extra.json
}

# ---- app ---------------------------------------------------------------------
# api + valkey. Everything api's entrypoint (migrations, admin-password
# bootstrap) or process itself reads.

resource "aws_iam_role" "app" {
  name               = "${var.name_prefix}-app"
  assume_role_policy = local.ec2_assume_role_policy
  tags               = { Name = "${var.name_prefix}-app", Component = "security" }
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name_prefix}-app"
  role = aws_iam_role.app.name
  tags = { Name = "${var.name_prefix}-app", Component = "security" }
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "app_extra" {
  statement {
    sid       = "ReadOwnParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = local.role_parameter_arns.app.allow
  }
  statement {
    sid       = "DenyOtherParameters"
    effect    = "Deny"
    actions   = local.ssm_read_actions
    resources = local.role_parameter_arns.app.deny
  }
  statement {
    sid       = "DenyParameterBulkReads"
    effect    = "Deny"
    actions   = ["ssm:GetParametersByPath", "ssm:GetParameterHistory"]
    resources = ["*"]
  }
  statement {
    sid       = "ReadConfigObject"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.blobstore.arn}/config/margince.yaml"]
  }
  statement {
    sid       = "ReadOwnSourceObject"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.blobstore.arn}/source/${var.image_tag}.zip"]
  }
  statement {
    sid       = "ReadWriteOwnBinaryCache"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.blobstore.arn}/binaries/app-${var.image_tag}.tar.gz"]
  }
  statement {
    sid     = "WriteOwnLogs"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = [
      "${aws_cloudwatch_log_group.app.arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "app_extra" {
  name   = "${var.name_prefix}-app-extra"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app_extra.json
}

# ---- worker --------------------------------------------------------------------
# Runs no migrations (scripts/deploy/worker-entrypoint.sh) and bootstraps no
# admin/org — no owner_dsn, no admin_password, no license.

resource "aws_iam_role" "worker" {
  name               = "${var.name_prefix}-worker"
  assume_role_policy = local.ec2_assume_role_policy
  tags               = { Name = "${var.name_prefix}-worker", Component = "security" }
}

resource "aws_iam_instance_profile" "worker" {
  name = "${var.name_prefix}-worker"
  role = aws_iam_role.worker.name
  tags = { Name = "${var.name_prefix}-worker", Component = "security" }
}

resource "aws_iam_role_policy_attachment" "worker_ssm" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "worker_extra" {
  statement {
    sid       = "ReadOwnParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = local.role_parameter_arns.worker.allow
  }
  statement {
    sid       = "DenyOtherParameters"
    effect    = "Deny"
    actions   = local.ssm_read_actions
    resources = local.role_parameter_arns.worker.deny
  }
  statement {
    sid       = "DenyParameterBulkReads"
    effect    = "Deny"
    actions   = ["ssm:GetParametersByPath", "ssm:GetParameterHistory"]
    resources = ["*"]
  }
  statement {
    sid       = "ReadConfigObject"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.blobstore.arn}/config/margince.yaml"]
  }
  statement {
    sid       = "ReadOwnSourceObject"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.blobstore.arn}/source/${var.image_tag}.zip"]
  }
  statement {
    sid       = "ReadWriteOwnBinaryCache"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.blobstore.arn}/binaries/worker-${var.image_tag}.tar.gz"]
  }
  statement {
    sid     = "WriteOwnLogs"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = [
      "${aws_cloudwatch_log_group.worker.arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "worker_extra" {
  name   = "${var.name_prefix}-worker-extra"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker_extra.json
}
