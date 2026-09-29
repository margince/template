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
  public_base_url          = "https://crm.example.com"
  image_tag                = "v0.1.0"
  admin_bootstrap_password = "test-only-password-not-real"
  acm_certificate_arn      = "arn:aws:acm:eu-central-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
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
    condition     = var.db_engine_version == "16"
    error_message = "Postgres must be pinned to the major version only."
  }

  assert {
    condition = anytrue([
      for r in aws_security_group.db.ingress : contains(r.security_groups, aws_security_group.ops.id)
    ])
    error_message = "The bootstrap host must be able to reach RDS."
  }
}
