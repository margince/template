# One customer-managed key for everything this stack stores at rest: RDS,
# ElastiCache, S3, EFS, SSM SecureString parameters, ECR, the SNS alert
# topic and the WAF log group. A CMK over the AWS-managed
# defaults buys two things a managed key cannot: a key-usage trail in
# CloudTrail (who decrypted what, when) and the ability to disable or
# schedule deletion of the key to cut off every one of these services at
# once, independent of anything IAM controls.
#
# One key, not six: this stack's blast-radius boundary is already the IAM
# grants below (only the ECS execution role and the blobstore IAM user can
# use it, and only for the specific actions each needs), so a second key per
# service would multiply the grants to manage without narrowing anything a
# compromised execution role could already reach through the secrets it
# holds. Split later if a real separation-of-duty requirement asks for it.
#
# Key policy: the first statement is the default AWS applies (full access to
# the account root), which delegates to IAM so the targeted grants in iam.tf
# can use the key. Any account principal with kms:* on * in IAM can use it
# too; restrict those IAM policies if that matters to you. The second
# statement lets CloudWatch alarms publish to the CMK-encrypted SNS topic
# (alarms.tf). CloudWatch is a service principal, not an IAM identity, so an
# IAM grant cannot give it the key and without this statement every alarm
# notification is dropped. The third statement lets CloudWatch Logs encrypt
# and decrypt the WAF log group (alb.tf), and only that log group: the
# encryption-context condition pins every use to that one log group ARN.
data "aws_iam_policy_document" "kms_data" {
  statement {
    sid       = "EnableIAMUserPermissions"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowCloudWatchAlarmsToSNS"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid = "AllowCloudWatchLogsForWafLogGroup"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:${local.waf_log_group_name}"]
    }
  }
}

resource "aws_kms_key" "data" {
  description             = "${var.name_prefix} CMK for RDS, ElastiCache, S3, EFS, SSM parameters, ECR, SNS alerts and WAF logs at rest"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms_data.json
  tags                    = { Name = "${var.name_prefix}-data", Component = "security" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.name_prefix}-data"
  target_key_id = aws_kms_key.data.key_id
}
