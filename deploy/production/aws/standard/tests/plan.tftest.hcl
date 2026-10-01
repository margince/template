# Offline checks with mocked providers: no AWS credentials, no network.
# Run with: terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-central-1a", "eu-central-1b", "eu-central-1c"] }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "random" {}

variables {
  public_base_url = "https://crm.example.com"
  image_refs = {
    api    = "source.example/margince/api:1970.42@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    worker = "source.example/margince/worker:1970.42@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    web    = "source.example/margince/web:1970.42@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  }
  admin_bootstrap_password = "test-only-password-not-real"
  acm_certificate_arn      = "arn:aws:acm:eu-central-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  license_token            = "test-licence"
}

run "fixes_hold" {
  command = plan

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  assert {
    condition = alltrue([
      for c in aws_lb_listener_rule.api_v1_and_ops.condition :
      !contains(flatten(c.path_pattern[*].values), "/metrics")
    ])
    error_message = "The ALB must not route /metrics from the internet to the api."
  }

  assert {
    condition     = aws_db_instance.this.engine_version == "16"
    error_message = "Postgres must be pinned to the major version only."
  }

  assert {
    condition = anytrue([
      for r in aws_security_group.db.ingress : contains(r.security_groups, aws_security_group.ops.id)
    ])
    error_message = "The bootstrap host must be able to reach RDS."
  }
}

run "defaults_plan" {
  command = plan

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  assert {
    condition     = var.waf_mode == "count"
    error_message = "WAF must default to count mode for the first rollout."
  }

  assert {
    condition = alltrue([
      for r in aws_wafv2_web_acl.alb.rule :
      length(r.override_action) == 0 || (length(r.override_action[0].count) == 1 && length(r.override_action[0].none) == 0)
    ])
    error_message = "In count mode every managed rule group must use override_action count."
  }

  assert {
    condition = alltrue([
      for r in aws_wafv2_web_acl.alb.rule :
      length(r.action) == 0 || (length(r.action[0].count) == 1 && length(r.action[0].block) == 0)
    ])
    error_message = "In count mode every custom rule must use action count."
  }

  assert {
    condition = toset([for r in aws_wafv2_web_acl.alb.rule : r.name]) == toset([
      "AWS-AWSManagedRulesAmazonIpReputationList",
      "AWS-AWSManagedRulesAnonymousIpList",
      "AWS-AWSManagedRulesCommonRuleSet",
      "AWS-AWSManagedRulesKnownBadInputsRuleSet",
      "AWS-AWSManagedRulesSQLiRuleSet",
      "AWS-AWSManagedRulesLinuxRuleSet",
      "RateLimitAuthPaths",
      "RateLimitPerIP",
    ])
    error_message = "Unexpected WAF rule set: six managed rule groups and two rate rules."
  }

  assert {
    condition = anytrue([
      for r in aws_wafv2_web_acl.alb.rule :
      r.name == "RateLimitPerIP" &&
      length(r.statement[0].rate_based_statement[0].scope_down_statement[0].not_statement) == 1 &&
      strcontains(r.statement[0].rate_based_statement[0].scope_down_statement[0].not_statement[0].statement[0].regex_match_statement[0].regex_string, "/webhooks/")
    ])
    error_message = "The global per-IP rate rule must exclude the webhook paths."
  }

  assert {
    condition     = length(aws_wafv2_web_acl_logging_configuration.alb.redacted_fields) == 3 && length(aws_wafv2_web_acl_logging_configuration.alb.logging_filter) == 0
    error_message = "WAF logging must redact authorization, cookie and query string, and keep every record in count mode."
  }

  assert {
    condition     = aws_cloudwatch_log_group.waf.name == "aws-waf-logs-margince" && aws_cloudwatch_log_group.waf.retention_in_days == 30
    error_message = "WAF log group must carry the aws-waf-logs- prefix and 30-day retention."
  }

  assert {
    condition = alltrue([
      for p in [
        aws_ssm_parameter.owner_dsn, aws_ssm_parameter.app_dsn, aws_ssm_parameter.redis_password,
        aws_ssm_parameter.keyvault_root_key, aws_ssm_parameter.webhook_key, aws_ssm_parameter.connector_state_key,
        aws_ssm_parameter.admin_password, aws_ssm_parameter.blobstore_access_key, aws_ssm_parameter.blobstore_secret_key,
        aws_ssm_parameter.rds_master_password, aws_ssm_parameter.license,
      ] : p.type == "SecureString" && p.tier == "Standard" && startswith(p.name, "/margince/")
    ])
    error_message = "Every credential must be a Standard-tier SecureString under /<name_prefix>/."
  }

  assert {
    condition = (
      length(aws_sns_topic_subscription.alert_email) == 0 &&
      aws_cloudwatch_metric_alarm.alb_elb_5xx.threshold == 25 &&
      aws_cloudwatch_metric_alarm.alb_target_5xx.threshold == 25 &&
      length(aws_cloudwatch_metric_alarm.alb_unhealthy_hosts) == 2 &&
      aws_cloudwatch_metric_alarm.alb_p95_latency.threshold == 2 &&
      length(aws_cloudwatch_metric_alarm.ecs_cpu) == 3 &&
      length(aws_cloudwatch_metric_alarm.ecs_memory) == 3 &&
      aws_cloudwatch_metric_alarm.rds_connections.threshold == 320 &&
      length(aws_cloudwatch_metric_alarm.rds_cpu_credit_balance) == 1 &&
      length(aws_cloudwatch_metric_alarm.redis_memory) == 2 &&
      length(aws_cloudwatch_metric_alarm.redis_engine_cpu) == 2 &&
      aws_cloudwatch_metric_alarm.waf_blocked_requests.threshold == 500
    )
    error_message = "Baseline alarms must always exist, with no email subscription unless alert_email is set."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.waf_blocked_requests.dimensions["Rule"] == "ALL" && aws_cloudwatch_metric_alarm.waf_blocked_requests.namespace == "AWS/WAFV2"
    error_message = "WAF blocked-requests alarm must watch the web-ACL-wide aggregate."
  }

  assert {
    condition     = contains(local.interface_endpoint_services, "ssm") && !contains(local.interface_endpoint_services, "secretsmanager")
    error_message = "Tasks read secrets through the ssm endpoint; the secretsmanager endpoint is unused."
  }
}

# Computed ARNs are unknown at plan; pin the ones the assertions compare.
run "defaults_encryption_and_wiring" {
  command = plan

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  override_resource {
    target          = aws_kms_key.data
    override_during = plan
    values          = { arn = "arn:aws:kms:eu-central-1:123456789012:key/11111111-1111-1111-1111-111111111111" }
  }

  override_resource {
    target          = aws_ssm_parameter.owner_dsn
    override_during = plan
    values          = { arn = "arn:aws:ssm:eu-central-1:123456789012:parameter/margince/owner-dsn" }
  }

  override_resource {
    target          = aws_ssm_parameter.rds_master_password
    override_during = plan
    values          = { arn = "arn:aws:ssm:eu-central-1:123456789012:parameter/margince/rds-master-password" }
  }

  assert {
    condition = alltrue([
      for p in [
        aws_ssm_parameter.owner_dsn, aws_ssm_parameter.app_dsn, aws_ssm_parameter.redis_password,
        aws_ssm_parameter.keyvault_root_key, aws_ssm_parameter.webhook_key, aws_ssm_parameter.connector_state_key,
        aws_ssm_parameter.admin_password, aws_ssm_parameter.blobstore_access_key, aws_ssm_parameter.blobstore_secret_key,
        aws_ssm_parameter.rds_master_password, aws_ssm_parameter.license,
      ] : p.key_id == aws_kms_key.data.arn
    ])
    error_message = "Every SSM parameter must be encrypted with the stack CMK."
  }

  assert {
    condition     = aws_cloudwatch_log_group.waf.kms_key_id == aws_kms_key.data.arn && aws_sns_topic.alerts.kms_master_key_id == aws_kms_key.data.arn
    error_message = "WAF log group and SNS alert topic must be encrypted with the stack CMK."
  }

  assert {
    condition = (
      length(local.shared_secrets) == 10 &&
      anytrue([for s in local.shared_secrets : s.name == "MARGINCE_OWNER_DSN" && s.valueFrom == aws_ssm_parameter.owner_dsn.arn]) &&
      contains(keys(local.task_ssm_parameters), "MARGINCE_LICENSE")
    )
    error_message = "Task secrets must be the 10 task SSM parameters; the RDS master password is never one of them."
  }
}

# Global bucket names, the web SG split, and the Valkey 7.2 pin.
run "naming_sg_split_and_cache_version" {
  command = plan

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  override_resource {
    target          = aws_security_group.ecs_tasks
    override_during = plan
    values          = { id = "sg-0ecs0000000000000" }
  }

  override_resource {
    target          = aws_security_group.web
    override_during = plan
    values          = { id = "sg-0web0000000000000" }
  }

  override_resource {
    target          = aws_security_group.vpc_endpoints
    override_during = plan
    values          = { id = "sg-0vpce000000000000" }
  }

  override_resource {
    target          = aws_security_group.alb
    override_during = plan
    values          = { id = "sg-0alb0000000000000" }
  }

  assert {
    condition     = var.aws_region == "eu-central-1"
    error_message = "Test expectations below assume the default region eu-central-1."
  }

  assert {
    condition = (
      aws_s3_bucket.blobstore.bucket == "margince-blobstore-123456789012-eu-central-1" &&
      aws_s3_bucket.alb_logs.bucket == "margince-alb-logs-123456789012-eu-central-1" &&
      endswith(aws_s3_bucket.blobstore.bucket, "-123456789012-eu-central-1") &&
      endswith(aws_s3_bucket.alb_logs.bucket, "-123456789012-eu-central-1")
    )
    error_message = "Bucket names must end with -<account_id>-<region>."
  }

  assert {
    condition = (
      toset(aws_ecs_service.web.network_configuration[0].security_groups) == toset(["sg-0web0000000000000"]) &&
      !contains(aws_ecs_service.web.network_configuration[0].security_groups, aws_security_group.ecs_tasks.id) &&
      contains(aws_ecs_service.api.network_configuration[0].security_groups, aws_security_group.ecs_tasks.id) &&
      !contains(aws_ecs_service.api.network_configuration[0].security_groups, aws_security_group.web.id)
    )
    error_message = "web must use its own SG, distinct from api/worker's ecs_tasks SG."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.web_from_alb.referenced_security_group_id == aws_security_group.alb.id &&
      aws_vpc_security_group_ingress_rule.web_from_alb.from_port == 8080 &&
      aws_vpc_security_group_egress_rule.web_to_vpc_endpoints.referenced_security_group_id == aws_security_group.vpc_endpoints.id &&
      aws_vpc_security_group_egress_rule.web_to_vpc_endpoints.from_port == 443 &&
      aws_vpc_security_group_egress_rule.web_to_internet.cidr_ipv4 == "0.0.0.0/0" &&
      length(aws_security_group.web.ingress) == 0
    )
    error_message = "web SG: 8080 from the ALB only; egress 443 to the endpoints SG and the internet (image pull)."
  }

  assert {
    condition = anytrue([
      for r in aws_security_group.vpc_endpoints.ingress : contains(r.security_groups, aws_security_group.web.id) && r.from_port == 443
    ])
    error_message = "The interface endpoints SG must admit the web SG on 443."
  }

  assert {
    condition = !anytrue([
      for sg in [aws_security_group.db, aws_security_group.redis, aws_security_group.efs] :
      anytrue([for r in sg.ingress : contains(r.security_groups, aws_security_group.web.id)])
    ])
    error_message = "web must have no path to RDS, Redis or EFS."
  }

  assert {
    condition = (
      aws_elasticache_replication_group.this.engine == "valkey" &&
      aws_elasticache_replication_group.this.engine_version == "7.2" &&
      aws_elasticache_parameter_group.this.family == "valkey7" &&
      aws_elasticache_replication_group.this.transit_encryption_mode == "required"
    )
    error_message = "ElastiCache must run Valkey 7.2 (family valkey7) with TLS required."
  }
}

run "long_name_prefix_is_refused" {
  command = plan
  variables {
    name_prefix = "margince-a-very-long-production-prefix"
  }
  expect_failures = [var.name_prefix]
}

run "block_mode_and_alert_email" {
  command = plan

  variables {
    waf_mode    = "block"
    alert_email = "ops@example.com"
  }

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  assert {
    condition = alltrue([
      for r in aws_wafv2_web_acl.alb.rule :
      length(r.override_action) == 0 || (
        r.name == "AWS-AWSManagedRulesAnonymousIpList"
        ? length(r.override_action[0].count) == 1
        : length(r.override_action[0].none) == 1
      )
    ])
    error_message = "Block mode: managed groups use none{}, except AnonymousIpList which stays count-only."
  }

  assert {
    condition = alltrue([
      for r in aws_wafv2_web_acl.alb.rule :
      length(r.action) == 0 || length(r.action[0].block) == 1
    ])
    error_message = "Block mode: custom rules use action block."
  }

  assert {
    condition     = length(aws_wafv2_web_acl_logging_configuration.alb.logging_filter) == 1
    error_message = "Block mode drops plain ALLOW records from WAF logs."
  }

  assert {
    condition     = length(aws_sns_topic_subscription.alert_email) == 1
    error_message = "alert_email subscribes to the alerts topic."
  }
}

run "images_follow_the_instance_release" {
  command = plan

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  assert {
    condition     = local.images == var.image_refs && output.image_refs == var.image_refs
    error_message = "AWS must deploy the three digest-pinned references supplied by the instance release unchanged."
  }

  assert {
    condition     = var.cpu_architecture == "X86_64" && aws_ecs_task_definition.api.runtime_platform[0].cpu_architecture == "X86_64"
    error_message = "The default architecture is X86_64; the selected instance release must include linux/amd64."
  }

  assert {
    condition     = output.image_platform == "linux/amd64"
    error_message = "image_platform must name the linux/amd64 image for the default X86_64 architecture."
  }
}

run "arm64_needs_the_arm64_image" {
  command = plan
  variables {
    cpu_architecture = "ARM64"
  }

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  assert {
    condition     = aws_ecs_task_definition.api.runtime_platform[0].cpu_architecture == "ARM64" && output.image_platform == "linux/arm64"
    error_message = "ARM64 tasks need the linux/arm64 image, and image_platform must say so."
  }
}

run "image_refs_must_be_digest_pinned" {
  command = plan
  variables {
    image_refs = {
      api    = "source.example/margince/api:latest"
      worker = "source.example/margince/worker:1970.42@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      web    = "source.example/margince/web:1970.42@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    }
  }
  expect_failures = [var.image_refs]
}

run "images_are_pulled_anonymously" {
  command = plan

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  assert {
    condition     = !strcontains(file("${path.module}/ecs.tf"), "repositoryCredentials") && !strcontains(file("${path.module}/iam.tf"), "secretsmanager:")
    error_message = "The registry is public: no task definition may carry pull credentials, and no role may read Secrets Manager."
  }
}

run "missing_licence_is_refused" {
  command = plan
  variables {
    license_token = ""
  }
  expect_failures = [var.license_token]
}

run "security_group_and_iam_descriptions_are_ascii" {
  command = plan

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  # EC2 accepts only a-zA-Z0-9. _-:/()#,@[]+=&;{}!$* in security group and
  # rule descriptions; IAM role descriptions reject non-ASCII characters.
  # Inline rules reference security group IDs, which are unknown at plan
  # time, so only the group and standalone rule descriptions are checked.
  assert {
    condition = alltrue([
      for d in concat(
        [for sg in [aws_security_group.alb, aws_security_group.ecs_tasks, aws_security_group.web, aws_security_group.db, aws_security_group.redis, aws_security_group.efs, aws_security_group.ops, aws_security_group.vpc_endpoints] : sg.description],
        [aws_vpc_security_group_ingress_rule.web_from_alb.description, aws_vpc_security_group_egress_rule.web_to_vpc_endpoints.description, aws_vpc_security_group_egress_rule.web_to_internet.description],
      ) : can(regex("^[a-zA-Z0-9. _:/()#,@\\[\\]+=&;{}!$*-]*$", d))
    ])
    error_message = "A security group or rule description uses a character EC2 refuses."
  }

  assert {
    condition = alltrue([
      for d in [aws_iam_role.execution.description, aws_iam_role.execution_web.description, aws_iam_role.task_api.description, aws_iam_role.task_worker.description, aws_iam_role.task_web.description, aws_iam_role.vpc_flow_logs.description, aws_iam_role.ops.description] :
      can(regex("^[ -~]*$", d))
    ])
    error_message = "An IAM role description uses a non-ASCII character."
  }
}
