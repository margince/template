# Daily EBS snapshots, always on, of the data volume
# and the root volume, selected by their Backup tag (ec2.tf): at 02:00 UTC,
# the 7 newest kept. Data Lifecycle Manager keeps its snapshots when the
# instance is replaced; deleting the policy stops new snapshots only.

resource "aws_iam_role" "dlm" {
  name = "${var.name_prefix}-dlm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  description = "Data Lifecycle Manager snapshots of the Margince light volumes"
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "daily" {
  description        = "${var.name_prefix} daily snapshots 7 kept"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = local.backup_tag

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["02:00"]
      }

      retain_rule {
        count = 7
      }

      copy_tags = true
    }
  }

  tags = { Name = "${var.name_prefix}-daily" }
}
