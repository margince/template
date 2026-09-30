# The license, the one value make deploy needs from the operator that
# Terraform knows, as an SSM SecureString with the AWS-managed alias/aws/ssm
# key. make deploy reads it from its own environment; the secret_exports
# output prints the command that fills it. The instance never reads it. The
# host adapter generates every other secret on the server
# (docs/deploy.md Section 5.6).

locals {
  # SSM rejects an empty value, so the parameter exists only when
  # license_token is set. nonsensitive() exposes only whether it is empty.
  license_set  = nonsensitive(var.license_token != "")
  license_name = "/${var.name_prefix}/margince-license"
}

resource "aws_ssm_parameter" "license" {
  count       = local.license_set ? 1 : 0
  name        = local.license_name
  description = "MARGINCE_LICENSE for make deploy"
  type        = "SecureString"
  tier        = "Standard"
  key_id      = "alias/aws/ssm"
  value       = var.license_token
  tags        = { Name = "${var.name_prefix}-margince-license" }
}
