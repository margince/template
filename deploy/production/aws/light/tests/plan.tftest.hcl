# Offline checks with mocked providers: no AWS credentials, no network.
# Run with: terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-central-1a", "eu-central-1b", "eu-central-1c"] }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "random" {}
mock_provider "archive" {
  mock_data "archive_file" {
    defaults = {
      output_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      output_md5    = "0123456789abcdef0123456789abcdef"
    }
  }
}

variables {
  public_base_url          = "https://crm.example.com"
  image_tag                = "v0.1.0"
  admin_bootstrap_password = "test-only-password-not-real"
  margince_source_dir      = "./tests/fixtures/margince-src"
}

run "fixes_hold" {
  command = plan

  # Computed values the assertions read, fixed at plan time.
  override_resource {
    target          = aws_eip.edge
    override_during = plan
    values          = { public_dns = "ec2-203-0-113-10.eu-central-1.compute.amazonaws.com" }
  }
  override_resource {
    target          = random_password.origin_verify
    override_during = plan
    values          = { result = "test-origin-secret" }
  }

  assert {
    condition     = one([for o in aws_cloudfront_distribution.this.origin : o.domain_name]) == aws_eip.edge.public_dns
    error_message = "CloudFront's origin must be the edge Elastic IP's DNS name, not an IP address."
  }

  assert {
    condition     = aws_instance.app.private_ip == cidrhost(aws_subnet.public.cidr_block, 10)
    error_message = "The app instance must keep its fixed private IP across replacements."
  }

  assert {
    condition     = strcontains(local.worker_user_data, "MARGINCE_BLOBSTORE_BUCKET=${aws_s3_bucket.blobstore.bucket}")
    error_message = "The worker must receive the blobstore bucket name."
  }

  assert {
    condition     = strcontains(local.nginx_conf, "location = /metrics  { return 404; }")
    error_message = "nginx must not proxy /metrics to the public internet."
  }

  assert {
    condition     = endswith(aws_s3_bucket.blobstore.bucket, "-123456789012")
    error_message = "The blobstore bucket name must carry the account id so it is globally unique."
  }

  # ---- Secrets: SSM Parameter Store, never Secrets Manager -------------------

  assert {
    condition = alltrue([
      for p in aws_ssm_parameter.secret :
      p.type == "SecureString" && p.tier == "Standard" && p.key_id == "alias/aws/ssm" && startswith(p.name, "/margince-light/")
    ])
    error_message = "Every secret must be a Standard-tier SecureString under /<name_prefix>/ encrypted with alias/aws/ssm."
  }

  assert {
    condition     = contains(keys(aws_ssm_parameter.secret), "rds_master_password") && contains(keys(aws_ssm_parameter.secret), "admin_password")
    error_message = "The RDS master and bootstrap admin passwords must be readable from SSM, not only from Terraform state."
  }

  assert {
    condition     = length(local.secret_parameters.rds_master_password.readers) == 0
    error_message = "No instance role may read the RDS master password."
  }

  assert {
    condition     = !contains(keys(aws_ssm_parameter.secret), "license") && strcontains(local.app_user_data, "echo \"MARGINCE_LICENSE=\" >>")
    error_message = "An empty license_token must create no SSM parameter (SSM rejects empty values) and write an empty MARGINCE_LICENSE instead."
  }

  assert {
    condition     = !anytrue([for s in local.worker_secrets : contains(["MARGINCE_OWNER_DSN", "MARGINCE_ADMIN_PASSWORD", "MARGINCE_LICENSE"], s.env_name)])
    error_message = "worker must not fetch owner_dsn, admin_password or license."
  }

  assert {
    condition     = length(local.app_secrets) == 9 && length(local.worker_secrets) == 7
    error_message = "app must fetch its 9 parameters (10 with a license) and worker its 7."
  }

  assert {
    condition = alltrue([
      for ud in [local.app_user_data, local.worker_user_data] :
      strcontains(ud, "aws ssm get-parameter") && strcontains(ud, "--with-decryption") && !strcontains(ud, "secretsmanager")
    ])
    error_message = "app/worker user-data must fetch secrets from SSM with decryption, not Secrets Manager."
  }

  assert {
    condition     = alltrue([for ud in [local.edge_user_data, local.app_user_data, local.worker_user_data] : length(ud) < 16384])
    error_message = "EC2 user data must stay under the 16 KB limit."
  }

  # ---- RDS: protected against deletion by default ----------------------------

  assert {
    condition     = aws_db_instance.this.deletion_protection == true && aws_db_instance.this.delete_automated_backups == false && aws_db_instance.this.skip_final_snapshot == false
    error_message = "RDS must have deletion protection on, keep automated backups after deletion, and take a final snapshot."
  }

  # ---- Changed source under the same tag must replace instances --------------

  assert {
    condition = alltrue([
      for ud in [local.edge_user_data, local.app_user_data, local.worker_user_data] :
      strcontains(ud, "0123456789abcdef")
    ])
    error_message = "Every instance's user data must carry the source archive hash, so changed source replaces it."
  }

  assert {
    condition = alltrue([
      for role, key in local.binary_cache_keys :
      key == "binaries/${role}-v0.1.0-0123456789abcdef.tar.gz"
    ]) && strcontains(local.app_user_data, "BINARY_KEY=\"binaries/app-v0.1.0-0123456789abcdef.tar.gz\"")
    error_message = "S3 binary cache keys must include both the tag and the source hash."
  }

  # ---- Versions: same pins as the Azure light stack -------------------------

  assert {
    condition = (
      strcontains(local.app_user_data, "docker.io/library/redis:7.2@sha256:6461ca4ac0c5c9d81d53685c3bf76aa81f464a9de6cf3a97b80a1da8d1bb1de4") &&
      strcontains(local.app_user_data, "dnf install -y docker ") &&
      !strcontains(local.app_user_data, "dnf install -y valkey") &&
      !strcontains(local.app_user_data, "valkey")
    )
    error_message = "app must run redis from the digest-pinned image under Docker, not the valkey dnf package."
  }

  assert {
    condition = (
      alltrue([for ud in [local.app_user_data, local.worker_user_data] : strcontains(ud, "postgresql16") && !strcontains(ud, "postgresql15")]) &&
      alltrue([for ud in [local.edge_user_data, local.app_user_data, local.worker_user_data] : strcontains(ud, "go.work") && strcontains(ud, "sha256sum -c") && !strcontains(ud, "GO_VERSION=1.")]) &&
      strcontains(local.edge_user_data, "nodejs.org/dist/latest-v") && !strcontains(local.edge_user_data, "NODE_VERSION=")
    )
    error_message = "Toolchains must come from the source pins (go.work, Dockerfile) with checksum verification, and the Postgres client must be 16."
  }

  # ---- No WAF; nginx does the filtering ---------------------------------------

  assert {
    condition     = aws_cloudfront_distribution.this.web_acl_id == null
    error_message = "light must not attach a WAF web ACL to CloudFront (by design, for cost)."
  }

  assert {
    condition     = strcontains(local.nginx_conf, "zone=auth:10m rate=30r/m") && strcontains(local.nginx_conf, "location = /v1/auth/login") && strcontains(local.nginx_conf, "location = /oauth/token")
    error_message = "nginx must rate-limit the credential endpoints per client IP, as in the Azure light stack, since light has no WAF."
  }

  # ---- Alarms on by default ---------------------------------------------------

  assert {
    condition     = length(aws_sns_topic.alerts) == 1 && length(aws_sns_topic_subscription.alert_email) == 0
    error_message = "The alerts topic must exist by default, with no email subscription unless alert_email is set."
  }

  assert {
    condition = (
      toset(keys(aws_cloudwatch_metric_alarm.system_status_check_failed)) == toset(["edge", "app", "worker"]) &&
      length(aws_cloudwatch_metric_alarm.instance_status_check_failed) == 3 &&
      length(aws_cloudwatch_metric_alarm.instance_cpu_high) == 3 &&
      length(aws_cloudwatch_metric_alarm.rds_free_storage_low) == 1 &&
      length(aws_cloudwatch_metric_alarm.rds_cpu_high) == 1 &&
      length(aws_cloudwatch_metric_alarm.rds_connections_high) == 1
    )
    error_message = "All EC2 and RDS alarms must exist by default."
  }

  assert {
    condition = alltrue([
      for a in aws_cloudwatch_metric_alarm.system_status_check_failed :
      contains(a.alarm_actions, "arn:aws:automate:eu-central-1:ec2:recover") && a.metric_name == "StatusCheckFailed_System"
    ])
    error_message = "Each instance's system status check alarm must trigger EC2 auto-recover."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.rds_free_storage_low[0].threshold == 2147483648
    error_message = "The RDS free-storage alarm threshold must be 2 GiB in bytes."
  }
}

run "alarms_disabled" {
  command = plan

  variables {
    enable_alarms = false
    alert_email   = "ops@example.com"
  }

  assert {
    condition = (
      length(aws_sns_topic.alerts) == 0 &&
      length(aws_sns_topic_subscription.alert_email) == 0 &&
      length(aws_cloudwatch_metric_alarm.system_status_check_failed) == 0 &&
      length(aws_cloudwatch_metric_alarm.rds_free_storage_low) == 0
    )
    error_message = "enable_alarms = false must create no topic, subscription or alarm."
  }
}

run "email_and_license" {
  command = plan

  variables {
    alert_email   = "ops@example.com"
    license_token = "test-license-token"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.alert_email) == 1 && aws_sns_topic_subscription.alert_email[0].endpoint == "ops@example.com"
    error_message = "Setting alert_email must subscribe it to the alerts topic."
  }

  assert {
    condition     = contains(keys(aws_ssm_parameter.secret), "license") && length(local.app_secrets) == 10 && length(local.worker_secrets) == 7
    error_message = "A license token must become an app-only SSM parameter."
  }

  assert {
    condition     = !strcontains(local.app_user_data, "echo \"MARGINCE_LICENSE=\" >>")
    error_message = "With a license parameter, user-data must not also write an empty MARGINCE_LICENSE."
  }
}

run "deletion_protection_can_be_disabled" {
  command = plan

  variables {
    db_deletion_protection = false
  }

  assert {
    condition     = aws_db_instance.this.deletion_protection == false && aws_db_instance.this.skip_final_snapshot == false
    error_message = "db_deletion_protection = false must turn protection off while still taking a final snapshot."
  }
}

run "rejects_unpinned_redis_image" {
  command = plan

  variables {
    redis_image = "redis:7.2"
  }

  expect_failures = [var.redis_image]
}

run "rejects_bad_alert_email" {
  command = plan

  variables {
    alert_email = "not-an-email"
  }

  expect_failures = [var.alert_email]
}

run "removed_waf_variable_is_refused" {
  command = plan
  variables {
    enable_waf = true
  }
  expect_failures = [var.enable_waf]
}
