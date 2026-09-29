# Basic alerting, on by default (var.enable_alarms). Every role here is a
# single instance with no peer to fail over to, so these alarms are the only
# signal that something is down. All of them use free basic metrics
# (EC2 status checks at 1-minute, CPU at 5-minute; RDS at 1-minute) and
# standard-resolution alarms (~$0.10/alarm/month, 11 alarms).
#
# Where alerts go: set var.alert_email (AWS sends a confirmation email that
# must be clicked), or subscribe anything else to the topic yourself:
#   aws sns subscribe --topic-arn "$(terraform output -raw alerts_topic_arn)" \
#     --protocol email --notification-endpoint you@example.com
#
# The topic is NOT encrypted at rest with SSE. CloudWatch alarms cannot
# publish to a topic encrypted with the AWS-managed alias/aws/sns key (its
# key policy cannot grant cloudwatch.amazonaws.com kms:GenerateDataKey*),
# so SSE would need a customer-managed KMS key, which this stack avoids
# (see rds.tf/s3.tf). Alarm payloads carry metric names and states, no
# secrets; delivery to SNS is TLS in transit either way.

locals {
  alarm_instances = var.enable_alarms ? {
    edge   = aws_instance.edge.id
    app    = aws_instance.app.id
    worker = aws_instance.worker.id
  } : {}
  alarm_topic = var.enable_alarms ? [aws_sns_topic.alerts[0].arn] : []
}

resource "aws_sns_topic" "alerts" {
  count = var.enable_alarms ? 1 : 0
  name  = "${var.name_prefix}-alerts"
  tags  = { Name = "${var.name_prefix}-alerts", Component = "observability" }
}

resource "aws_sns_topic_subscription" "alert_email" {
  count     = var.enable_alarms && var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---- EC2, per instance ---------------------------------------------------------

# Underlying host/hardware failure. EC2's recover action migrates the
# instance to healthy hardware keeping its instance ID, private IP (app's
# fixed IP included), Elastic IP and EBS volumes. "missing" keeps the prior
# state on no data, so a deliberately stopped instance never triggers a
# recover attempt.
resource "aws_cloudwatch_metric_alarm" "system_status_check_failed" {
  for_each = local.alarm_instances

  alarm_name          = "${var.name_prefix}-${each.key}-system-status-check-failed"
  alarm_description   = "${each.key} (${each.value}) failed its EC2 system status check for 2 minutes; EC2 auto-recover triggered."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"

  alarm_actions = concat(["arn:aws:automate:${var.aws_region}:ec2:recover"], local.alarm_topic)
  ok_actions    = local.alarm_topic

  tags = { Name = "${var.name_prefix}-${each.key}-system-status-check-failed", Component = "observability" }
}

# Guest OS failure (kernel panic, exhausted memory, broken networking). Not
# fixed by recover; an operator reboots or replaces the instance. Missing
# data here means the instance is not reporting, i.e. down: breaching.
resource "aws_cloudwatch_metric_alarm" "instance_status_check_failed" {
  for_each = local.alarm_instances

  alarm_name          = "${var.name_prefix}-${each.key}-instance-status-check-failed"
  alarm_description   = "${each.key} (${each.value}) failed its EC2 instance status check for 3 minutes; reboot or replace it (terraform taint aws_instance.${each.key})."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  dimensions          = { InstanceId = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = local.alarm_topic
  ok_actions    = local.alarm_topic

  tags = { Name = "${var.name_prefix}-${each.key}-instance-status-check-failed", Component = "observability" }
}

# Sustained CPU. On T-family instances (unlimited mode, the t4g default)
# this also means surplus-credit charges are accruing.
resource "aws_cloudwatch_metric_alarm" "instance_cpu_high" {
  for_each = local.alarm_instances

  alarm_name          = "${var.name_prefix}-${each.key}-cpu-high"
  alarm_description   = "${each.key} (${each.value}) averaged over 90% CPU for 15 minutes."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = each.value }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 90
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_topic
  ok_actions    = local.alarm_topic

  tags = { Name = "${var.name_prefix}-${each.key}-cpu-high", Component = "observability" }
}

# ---- RDS -------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${var.name_prefix}-db-free-storage-low"
  alarm_description   = "RDS ${aws_db_instance.this.identifier} has under 2 GiB free storage (storage autoscaling caps at 4x allocated)."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2 * 1024 * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_topic
  ok_actions    = local.alarm_topic

  tags = { Name = "${var.name_prefix}-db-free-storage-low", Component = "observability" }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${var.name_prefix}-db-cpu-high"
  alarm_description   = "RDS ${aws_db_instance.this.identifier} averaged over 90% CPU for 15 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 90
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_topic
  ok_actions    = local.alarm_topic

  tags = { Name = "${var.name_prefix}-db-cpu-high", Component = "observability" }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${var.name_prefix}-db-connections-high"
  alarm_description   = "RDS ${aws_db_instance.this.identifier} held over ${var.db_max_connections_alarm_threshold} connections for 15 minutes; close to max_connections."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.db_max_connections_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_topic
  ok_actions    = local.alarm_topic

  tags = { Name = "${var.name_prefix}-db-connections-high", Component = "observability" }
}
