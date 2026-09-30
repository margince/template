# Path rules mirror docs/deployment.md's "Routing" table exactly: everything
# listed here goes to the api service; everything else, "/" included, is the
# listener's default action to the web (SPA) service.

# ---- Access log bucket -------------------------------------------------------
# Shared by the ALB's own access logs (this file) and the blobstore bucket's
# server access logs (s3.tf), under separate prefixes — both destinations
# have the identical constraint (same region, same account, SSE-S3 only, not
# this stack's own CMK: ALB access logging documents this explicitly,
# docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html,
# "The only server-side encryption option that's supported is Amazon
# S3-managed keys (SSE-S3)"; S3 server access logging's own doc gives the
# identical requirement), so one bucket serves both rather than standing up
# a second one to hold nothing but a different prefix. This is why this
# bucket uses AES256 while every other bucket in this stack uses this
# stack's own CMK — not an inconsistency, a constraint of the two services
# being logged.
# Same account+region suffix as s3.tf's blobstore bucket (local.bucket_suffix):
# bucket names are global across all AWS accounts.
resource "aws_s3_bucket" "alb_logs" {
  bucket = "${var.name_prefix}-alb-logs-${local.bucket_suffix}"
  tags   = { Name = "${var.name_prefix}-alb-logs", Component = "observability" }

  lifecycle {
    precondition {
      condition     = length("${var.name_prefix}-alb-logs-${local.bucket_suffix}") <= 63
      error_message = "ALB log bucket name exceeds S3's 63-character limit; shorten name_prefix."
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Access logs are an audit trail, not application data — 90 days is enough to
# investigate an incident without keeping request logs forever. Same rule
# shape as s3.tf's noncurrent-version expiration, applied to current objects
# here since this bucket carries no versioning to begin with (nothing ever
# overwrites a delivered log file).
resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire-old-access-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
  }
}

# Current, non-legacy bucket policy per the doc above: the log delivery
# service principal, not a region-specific numeric ELB account ID. The
# account-scoped resource path plus the aws:SourceArn condition are both the
# doc's own "security best practices" — the path alone stops a same-account
# bucket-name squatter, aws:SourceArn additionally stops any OTHER account's
# load balancer from writing here even if it somehow named this bucket.
data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid     = "AWSLogDeliveryWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }
    resources = ["${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:elasticloadbalancing:${var.aws_region}:${data.aws_caller_identity.current.account_id}:loadbalancer/*"]
    }
  }

  # This bucket also carries s3.tf's blobstore access logs, under the "s3/"
  # prefix — same SSE-S3-only, same-region, same-account constraints as the
  # ALB logs above (docs.aws.amazon.com/AmazonS3/latest/userguide/enable-server-access-logging.html),
  # so one bucket serves both rather than standing up a second one to hold
  # nothing but a different prefix.
  statement {
    sid     = "S3ServerAccessLogsPolicy"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }
    resources = ["${aws_s3_bucket.alb_logs.arn}/s3/*"]
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.blobstore.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_logs.json
}

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  # A header with an invalid field name is otherwise forwarded to the target
  # as-is rather than dropped at the ALB — the parsing boundary this exists
  # to enforce (CWE-444, request smuggling via inconsistent interpretation).
  drop_invalid_header_fields = true

  # AWS's own default is false: a fat-fingered destroy or apply-time replace
  # would otherwise take down the one public entry point with no confirmation.
  enable_deletion_protection = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }

  tags = { Name = "${var.name_prefix}-alb", Component = "edge" }

  # Every request this ALB ever serves is deniable by default until the
  # bucket policy above exists — ELB validates write access to the bucket at
  # creation/update time, not just at the first log flush.
  depends_on = [aws_s3_bucket_policy.alb_logs]
}

# HTTP, not HTTPS, from here to the ECS targets — deliberately, matching the
# product's own architecture: cmd/api serves plain HTTP and terminates TLS
# ahead of itself (docs/reference/configuration.md's --metrics-token row
# states this explicitly). TLS terminates at the ALB; the hop from here to
# the target stays inside this VPC's private subnets, never on the public
# internet. Re-encrypting it would ask the ECS targets to speak a protocol
# the api binary does not implement.
resource "aws_lb_target_group" "api" {
  name        = "${var.name_prefix}-api"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${var.name_prefix}-api", Component = "edge" }
}

resource "aws_lb_target_group" "web" {
  name        = "${var.name_prefix}-web"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${var.name_prefix}-web", Component = "edge" }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = { Name = "${var.name_prefix}-http-redirect", Component = "edge" }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }

  tags = { Name = "${var.name_prefix}-https", Component = "edge" }
}

resource "aws_lb_listener_rule" "api_v1_and_ops" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  condition {
    path_pattern {
      values = ["/v1*", "/healthz", "/readyz"]
    }
  }

  tags = { Name = "${var.name_prefix}-api-v1-and-ops", Component = "edge" }
}

resource "aws_lb_listener_rule" "api_webhooks" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  condition {
    path_pattern {
      values = local.webhook_paths
    }
  }

  tags = { Name = "${var.name_prefix}-api-webhooks", Component = "edge" }
}

resource "aws_lb_listener_rule" "api_mcp_oauth" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 30

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  condition {
    path_pattern {
      values = [
        "/oauth/*",
        "/mcp*",
        "/.well-known/oauth-authorization-server",
        "/.well-known/oauth-protected-resource",
        "/.well-known/oauth-protected-resource/mcp",
      ]
    }
  }

  tags = { Name = "${var.name_prefix}-api-mcp-oauth", Component = "edge" }
}

# ---- WAF: the ALB is this stack's one public entry point --------------------
# Rollout: var.waf_mode = "count" (default) turns every managed rule group
# into override_action count{} and every custom rule into action count{}, so
# nothing is blocked and every would-be block shows up in the WAF log group
# and in sampled requests. After about a week of real traffic, add
# rule_action_override entries for whatever false positives turned up, then
# set waf_mode = "block" (override_action none{}, action block{}). README
# "WAF rollout" has the queries to run.
#
# Priority order (lower runs first):
#   10  AmazonIpReputationList  known-malicious sources, before anything else
#   20  RateLimitAuthPaths      100 per IP per 5 minutes on credential endpoints
#   30  RateLimitPerIP          2000 per IP per 5 minutes, webhooks excluded
#   40  AnonymousIpList         ALWAYS count-only: VPN/Tor/hosting-provider
#                               labels for the logs, real users use VPNs
#   50  CommonRuleSet           SizeRestrictions_BODY always count
#   60  KnownBadInputsRuleSet
#   70  SQLiRuleSet
#   80  LinuxRuleSet            the api/worker images are Linux (LFI etc.)
#
# About 1,405 WCU, inside the 1,500 included in the web ACL price (each
# further 500 WCU adds a per-request charge). Check AWS's figure before
# adding a rule group.

locals {
  # Exactly the paths the api_webhooks listener rule forwards. Provider
  # webhook traffic (Google, Microsoft Graph, HubSpot) is HMAC-verified by
  # the api and arrives in bursts from shared provider IPs, so it is exempt
  # from the per-IP global rate limit.
  webhook_paths = ["/webhooks/gmail", "/webhooks/graph", "/webhooks/hubspot"]

  # The api's credential-accepting endpoints (identity module middleware), the
  # same list as the Azure stack: password login, forgot/reset password, OAuth
  # token and dynamic client registration. An optional trailing slash is
  # matched too.
  waf_auth_paths = ["/v1/auth/login", "/v1/auth/forgot-password", "/v1/auth/reset-password", "/oauth/token", "/oauth/register"]

  waf_block = var.waf_mode == "block"

  # Regex-escape each path, then anchor. One regex_match_statement costs far
  # fewer WCUs than an or_statement of byte matches, each with its own
  # text transformation.
  waf_webhook_regex = "^(${join("|", [for p in local.webhook_paths : replace(p, "/[.+*?^$(){}|\\[\\]\\\\]/", "\\$0")])})$"
  waf_auth_regex    = "^(${join("|", [for p in local.waf_auth_paths : replace(p, "/[.+*?^$(){}|\\[\\]\\\\]/", "\\$0")])})/?$"

  waf_managed_rule_groups = [
    { name = "AWSManagedRulesAmazonIpReputationList", priority = 10, metric = "ip-reputation", count_only = false, count_rules = [] },
    { name = "AWSManagedRulesAnonymousIpList", priority = 40, metric = "anonymous-ip", count_only = true, count_rules = [] },
    # SizeRestrictions_BODY blocks every request body over 8 KB, which
    # rejects attachment uploads, MCP payloads and webhook batches. Count it
    # in both modes; the ALB and the api still bound body size.
    { name = "AWSManagedRulesCommonRuleSet", priority = 50, metric = "common-rule-set", count_only = false, count_rules = ["SizeRestrictions_BODY"] },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 60, metric = "known-bad-inputs", count_only = false, count_rules = [] },
    # The api's store is Postgres, reached through storekit's placeholder
    # derivation; this is the network-edge layer for the same attack class,
    # not a substitute for it.
    { name = "AWSManagedRulesSQLiRuleSet", priority = 70, metric = "sqli", count_only = false, count_rules = [] },
    { name = "AWSManagedRulesLinuxRuleSet", priority = 80, metric = "linux", count_only = false, count_rules = [] },
  ]

  waf_log_group_name = "aws-waf-logs-${var.name_prefix}"
}

resource "aws_wafv2_web_acl" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Managed-rule and rate-limit protection for the ${var.name_prefix} public ALB (mode: ${var.waf_mode})"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.waf_managed_rule_groups
    content {
      name     = "AWS-${rule.value.name}"
      priority = rule.value.priority
      override_action {
        dynamic "none" {
          for_each = local.waf_block && !rule.value.count_only ? [1] : []
          content {}
        }
        dynamic "count" {
          for_each = local.waf_block && !rule.value.count_only ? [] : [1]
          content {}
        }
      }
      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"
          dynamic "rule_action_override" {
            for_each = rule.value.count_rules
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = "${var.name_prefix}-${rule.value.metric}"
      }
    }
  }

  # backend/internal/modules/identity/handlers.go's own login limiters are,
  # by their own comment, "single-binary scope": in-memory per api TASK, not
  # shared across the fleet, so every task autoscaling adds raises the
  # effective fleet-wide login budget. This rule is the one point that sees
  # traffic before it fans out to any task. URL_DECODE so an encoded path
  # (/v1/auth/%6Cogin, which Go's mux still routes to login) cannot slip
  # past it. Blocked requests get 429, not 403, so clients back off.
  rule {
    name     = "RateLimitAuthPaths"
    priority = 20
    action {
      dynamic "block" {
        for_each = local.waf_block ? [1] : []
        content {
          custom_response {
            response_code = 429
          }
        }
      }
      dynamic "count" {
        for_each = local.waf_block ? [] : [1]
        content {}
      }
    }
    statement {
      rate_based_statement {
        limit              = 100
        aggregate_key_type = "IP"
        scope_down_statement {
          regex_match_statement {
            regex_string = local.waf_auth_regex
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "URL_DECODE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "${var.name_prefix}-rate-limit-auth"
    }
  }

  # Global per-IP bound (2000 per 5-minute window): generous for a
  # real user driving the SPA, tight enough to bound one client hammering the
  # api. The scope-down EXCLUDES the exact webhook paths. No text
  # transformation there on purpose: an encoded webhook path simply fails
  # the exclusion and is rate limited like everything else, the safe
  # direction.
  rule {
    name     = "RateLimitPerIP"
    priority = 30
    action {
      dynamic "block" {
        for_each = local.waf_block ? [1] : []
        content {
          custom_response {
            response_code = 429
          }
        }
      }
      dynamic "count" {
        for_each = local.waf_block ? [] : [1]
        content {}
      }
    }
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
        scope_down_statement {
          not_statement {
            statement {
              regex_match_statement {
                regex_string = local.waf_webhook_regex
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "${var.name_prefix}-rate-limit"
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = true
    metric_name                = "${var.name_prefix}-alb-waf"
  }

  tags = { Name = "${var.name_prefix}-alb", Component = "edge" }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.alb.arn
}

# The "aws-waf-logs-" prefix is not stylistic: WAF only accepts a CloudWatch
# Logs destination whose name carries it. Encrypted under the stack CMK;
# kms.tf's AllowCloudWatchLogsForWafLogGroup statement (pinned to this log
# group's ARN by encryption context) is what lets CloudWatch Logs use the key.
resource "aws_cloudwatch_log_group" "waf" {
  name              = local.waf_log_group_name
  retention_in_days = 30
  kms_key_id        = aws_kms_key.data.arn
  tags              = { Name = "${var.name_prefix}-waf-logs", Component = "observability" }
}

resource "aws_wafv2_web_acl_logging_configuration" "alb" {
  resource_arn            = aws_wafv2_web_acl.alb.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # WAF logs the full request by default. Without redaction every bearer
  # token, session cookie and OAuth code/state query parameter that crossed
  # the ALB would sit in plaintext in this log group. Redaction only affects
  # what is written; WAF still evaluates the real values.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
  redacted_fields {
    query_string {}
  }

  # Count mode logs everything: the point of the count phase is seeing which
  # requests WOULD have been blocked, and those carry an ALLOW terminating
  # action with the matching rules listed as non-terminating. Block mode keeps
  # only BLOCK, COUNT and EXCLUDED_AS_COUNT records (what a rule acted on or
  # would have), and drops plain ALLOW traffic, which is most of the volume
  # and already in the ALB access logs.
  dynamic "logging_filter" {
    for_each = local.waf_block ? [1] : []
    content {
      default_behavior = "DROP"
      filter {
        behavior    = "KEEP"
        requirement = "MEETS_ANY"
        condition {
          action_condition {
            action = "BLOCK"
          }
        }
        condition {
          action_condition {
            action = "COUNT"
          }
        }
        condition {
          action_condition {
            action = "EXCLUDED_AS_COUNT"
          }
        }
      }
    }
  }
}
