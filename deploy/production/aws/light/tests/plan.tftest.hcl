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
mock_provider "archive" {}

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
}
