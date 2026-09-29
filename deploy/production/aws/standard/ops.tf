# Access for the one-time bootstrap steps in the README (database roles,
# margince.yaml on EFS). The DB and EFS security groups admit only ECS tasks
# and this group, so an operator launches a temporary EC2 instance in a
# private subnet with this security group and instance profile, connects
# through SSM Session Manager (no SSH, no public IP), and terminates it when
# done. The group and role cost nothing while no instance uses them.

resource "aws_security_group" "ops" {
  name_prefix = "${var.name_prefix}-ops-"
  description = "Temporary bootstrap host: no ingress; egress for SSM, package installs, RDS and EFS."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name_prefix}-ops", Component = "operations" }

  egress {
    description = "SSM, package repositories, RDS, EFS"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

data "aws_iam_policy_document" "ops_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ops" {
  name_prefix        = "${var.name_prefix}-ops-"
  description        = "Temporary bootstrap host: SSM Session Manager, and mount plus write on the EFS config access point."
  assume_role_policy = data.aws_iam_policy_document.ops_assume.json
  tags               = { Name = "${var.name_prefix}-ops", Component = "operations" }
}

resource "aws_iam_role_policy_attachment" "ops_ssm" {
  role       = aws_iam_role.ops.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The EFS file-system policy (efs.tf) carries only a Deny, so an IAM Allow is
# the only way to mount. ClientWrite, unlike the task roles, because this host
# copies margince.yaml and the RDS CA bundle onto the volume.
data "aws_iam_policy_document" "ops_efs" {
  statement {
    sid       = "MountAndWriteConfigVolume"
    actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
    resources = [aws_efs_file_system.config.arn]
    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"
      values   = [aws_efs_access_point.config.arn]
    }
  }
}

resource "aws_iam_role_policy" "ops_efs" {
  name   = "${var.name_prefix}-ops-efs"
  role   = aws_iam_role.ops.id
  policy = data.aws_iam_policy_document.ops_efs.json
}

resource "aws_iam_instance_profile" "ops" {
  name_prefix = "${var.name_prefix}-ops-"
  role        = aws_iam_role.ops.name
}
