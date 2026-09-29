# Three EC2 instances, not one: edge (nginx + built frontend, public-facing
# via CloudFront), app (api + a natively-installed valkey), worker. No ASG,
# no launch template — a replacement means re-running `terraform apply`
# (or, for an in-place rebuild, `terraform taint aws_instance.<role>` and
# applying) rather than traffic shifting to a healthy peer, because there is
# no peer. See this stack's README for what that tradeoff costs.
#
# No containers anywhere in this file: each instance compiles its own piece
# from source at boot (templates/user_data-*.sh.tpl) using the native Go/
# Node toolchain, not docker buildx — see build.tf for where the shared
# source archive comes from.

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.cpu_architecture}"
}

locals {
  # var.public_base_url is a full URL (scheme + host); nginx's server_name
  # and the ACM certificate (cloudfront.tf) both need just the host. Fails
  # at plan time on a malformed URL rather than silently issuing a cert for
  # the wrong name.
  domain = regex("^https?://([^/:]+)", var.public_base_url)[0]

  # The app's private IP is fixed, not assigned by AWS. edge's nginx conf and
  # worker's MARGINCE_REDIS are built from it, and both instances have
  # user_data_replace_on_change, so an AWS-assigned IP would turn every app
  # replacement into a replacement of all three instances.
  app_private_ip = cidrhost(aws_subnet.public.cidr_block, 10)

  nginx_conf = templatefile("${path.module}/templates/nginx.conf.tftpl", {
    domain               = local.domain
    app_private_ip       = local.app_private_ip
    origin_verify_secret = random_password.origin_verify.result
  })

  # One entry per Secrets Manager secret a given role reads — mirrors
  # iam.tf's own per-role statement lists exactly, so adding a secret to one
  # without the other is the kind of drift `iam.tf`'s ReadOwnSecrets
  # statement (not this list) actually enforces; this is just what gets
  # fetched into that role's .env.
  app_secrets = [
    { env_name = "MARGINCE_OWNER_DSN", secret_id = aws_secretsmanager_secret.owner_dsn.name },
    { env_name = "MARGINCE_DSN", secret_id = aws_secretsmanager_secret.app_dsn.name },
    { env_name = "MARGINCE_REDIS_PASSWORD", secret_id = aws_secretsmanager_secret.redis_password.name },
    { env_name = "MARGINCE_KEYVAULT_ROOT_KEY", secret_id = aws_secretsmanager_secret.keyvault_root_key.name },
    { env_name = "MARGINCE_WEBHOOK_KEY", secret_id = aws_secretsmanager_secret.webhook_key.name },
    { env_name = "MARGINCE_CONNECTOR_STATE_KEY", secret_id = aws_secretsmanager_secret.connector_state_key.name },
    { env_name = "MARGINCE_ADMIN_PASSWORD", secret_id = aws_secretsmanager_secret.admin_password.name },
    { env_name = "MARGINCE_LICENSE", secret_id = aws_secretsmanager_secret.license.name },
    { env_name = "MARGINCE_BLOBSTORE_ACCESS_KEY", secret_id = aws_secretsmanager_secret.blobstore_access_key.name },
    { env_name = "MARGINCE_BLOBSTORE_SECRET_KEY", secret_id = aws_secretsmanager_secret.blobstore_secret_key.name },
  ]
  worker_secrets = [
    { env_name = "MARGINCE_DSN", secret_id = aws_secretsmanager_secret.app_dsn.name },
    { env_name = "MARGINCE_REDIS_PASSWORD", secret_id = aws_secretsmanager_secret.redis_password.name },
    { env_name = "MARGINCE_KEYVAULT_ROOT_KEY", secret_id = aws_secretsmanager_secret.keyvault_root_key.name },
    { env_name = "MARGINCE_WEBHOOK_KEY", secret_id = aws_secretsmanager_secret.webhook_key.name },
    { env_name = "MARGINCE_CONNECTOR_STATE_KEY", secret_id = aws_secretsmanager_secret.connector_state_key.name },
    { env_name = "MARGINCE_BLOBSTORE_ACCESS_KEY", secret_id = aws_secretsmanager_secret.blobstore_access_key.name },
    { env_name = "MARGINCE_BLOBSTORE_SECRET_KEY", secret_id = aws_secretsmanager_secret.blobstore_secret_key.name },
  ]

  common_build_vars = {
    aws_region        = var.aws_region
    blobstore_bucket  = aws_s3_bucket.blobstore.bucket
    source_object_key = aws_s3_object.source.key
    image_tag         = var.image_tag
  }

  edge_user_data = templatefile("${path.module}/templates/user_data-edge.sh.tpl", merge(local.common_build_vars, {
    nginx_conf_b64 = base64encode(local.nginx_conf)
    log_group      = aws_cloudwatch_log_group.edge.name
  }))

  app_user_data = templatefile("${path.module}/templates/user_data-app.sh.tpl", merge(local.common_build_vars, {
    public_base_url  = var.public_base_url
    redis_host       = "127.0.0.1"
    blobstore_bucket = aws_s3_bucket.blobstore.bucket
    secrets          = local.app_secrets
    log_group        = aws_cloudwatch_log_group.app.name
  }))

  worker_user_data = templatefile("${path.module}/templates/user_data-worker.sh.tpl", merge(local.common_build_vars, {
    public_base_url = var.public_base_url
    redis_host      = local.redis_host
    secrets         = local.worker_secrets
    log_group       = aws_cloudwatch_log_group.worker.name
  }))
}

# Shared-secret CloudFront injects on every request to the origin
# (cloudfront.tf's custom_header) and nginx checks (templates/nginx.conf.tftpl)
# — defense in depth beyond the origin-facing-prefix-list SG restriction
# alone (network.tf): even a request that somehow reached edge's SG from
# CloudFront's own IP range without going through the distribution gets
# rejected for missing this header.
resource "random_password" "origin_verify" {
  length  = 32
  special = false
}

resource "aws_instance" "edge" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.edge.id]
  iam_instance_profile   = aws_iam_instance_profile.edge.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  user_data                   = local.edge_user_data
  user_data_replace_on_change = true

  # The AMI comes from the "latest" SSM parameter, which AWS updates every few
  # weeks. Without this, the next unrelated apply after an update destroys and
  # rebuilds the instance. Taint the instance to move it to a newer AMI.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = "${var.name_prefix}-edge", Component = "compute" }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  private_ip = local.app_private_ip

  user_data                   = local.app_user_data
  user_data_replace_on_change = true

  # The AMI comes from the "latest" SSM parameter, which AWS updates every few
  # weeks. Without this, the next unrelated apply after an update destroys and
  # rebuilds the instance. Taint the instance to move it to a newer AMI.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = "${var.name_prefix}-app", Component = "compute" }
}

resource "aws_instance" "worker" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.worker.id]
  iam_instance_profile   = aws_iam_instance_profile.worker.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  user_data                   = local.worker_user_data
  user_data_replace_on_change = true

  # The AMI comes from the "latest" SSM parameter, which AWS updates every few
  # weeks. Without this, the next unrelated apply after an update destroys and
  # rebuilds the instance. Taint the instance to move it to a newer AMI.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = "${var.name_prefix}-worker", Component = "compute" }
}

# A fixed public IP for edge. CloudFront's origin is this address's DNS name
# (cloudfront.tf), so a stop/start or a replacement of edge does not leave
# CloudFront pointing at an address the instance no longer has.
resource "aws_eip" "edge" {
  domain   = "vpc"
  instance = aws_instance.edge.id
  tags     = { Name = "${var.name_prefix}-edge", Component = "network" }
}
