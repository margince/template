# CloudFront is the public entry point, not the edge EC2 instance's own IP —
# see network.tf's own note on why sg-edge only admits CloudFront's
# origin-facing prefix list. This trades one more managed service for not
# handing the raw internet a direct line to an EC2 instance; it costs far
# less than the full stack's ALB (pay-per-request, no hourly charge) and
# gets TLS/caching/optional-WAF for free.
#
# ACM certs for a CloudFront custom-domain alias MUST be requested in
# us-east-1 regardless of where the rest of this stack lives (versions.tf's
# aws.us_east_1 provider alias) — same for the WAFv2 web ACL below.
#
# This stack has no Route53 integration (DNS is an external, manual step —
# see the README), so ACM's DNS validation is ALSO a manual step: run the
# targeted apply for aws_acm_certificate.this first, add the CNAME record
# `acm_validation_record` outputs, THEN apply aws_acm_certificate_validation.this.

resource "aws_acm_certificate" "this" {
  provider          = aws.us_east_1
  domain_name       = local.domain
  validation_method = "DNS"

  lifecycle { create_before_destroy = true }

  tags = { Name = "${var.name_prefix}-cert", Component = "network" }
}

resource "aws_acm_certificate_validation" "this" {
  provider        = aws.us_east_1
  certificate_arn = aws_acm_certificate.this.arn
}

# Managed rule groups only — no custom rules to tune, same reasoning as the
# rest of this stack's toggles: a sensible baseline, not a decision this
# stack makes silently on cost/false-positive tradeoffs var.enable_waf itself
# already gates.
resource "aws_wafv2_web_acl" "this" {
  count    = var.enable_waf ? 1 : 0
  provider = aws.us_east_1
  name     = "${var.name_prefix}-waf"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 0
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${var.name_prefix}-waf", Component = "network" }
}

resource "aws_cloudfront_distribution" "this" {
  enabled     = true
  aliases     = [local.domain]
  price_class = "PriceClass_100" # North America + Europe only — cheapest tier, matching this stack's cost floor elsewhere
  web_acl_id  = var.enable_waf ? aws_wafv2_web_acl.this[0].arn : null

  origin {
    origin_id   = "edge"
    domain_name = aws_instance.edge.public_ip

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # plain HTTP inside AWS's own backbone to the origin — TLS is terminated HERE, at CloudFront
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Defense in depth beyond the SG prefix-list restriction (network.tf) —
    # nginx (templates/nginx.conf.tftpl) rejects any request missing this
    # exact value.
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }
  }

  default_cache_behavior {
    target_origin_id       = "edge"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    # This proxies a dynamic app, not a CDN-cacheable static site — forward
    # everything, cache nothing. A future pass could carve out /assets/ with
    # its own cache behavior (frontend/nginx.conf already marks those
    # immutable), but correctness came first here.
    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies {
        forward = "all"
      }
    }
    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.this.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = { Name = "${var.name_prefix}-cdn", Component = "network" }
}
