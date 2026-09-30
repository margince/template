# Basic alarms (var.enable_alarms, on by default), with the same thresholds
# as the Azure light stack. The instance has no peer, so these are the
# signal that Margince is down. They use free basic metrics and
# standard-resolution alarms (about USD 0.10 per alarm per month, 3 alarms).
# No disk alarm: the CloudWatch agent is not installed.
#
# Receivers: alert_email (AWS sends a confirmation link first), or subscribe
# anything else to the topic:
#   aws sns subscribe --topic-arn "$(terraform output -raw alerts_topic_arn)" \
#     --protocol email --notification-endpoint you@example.com
#
# The topic has no SSE: CloudWatch cannot publish to a topic encrypted with
# the AWS-managed alias/aws/sns key. Alarm payloads hold no secrets.

locals {
  alarm_topic = var.enable_alarms ? [aws_sns_topic.alerts[0].arn] : []
}

resource "aws_sns_topic" "alerts" {
  count = var.enable_alarms ? 1 : 0
  name  = "${var.name_prefix}-alerts"
  tags  = { Name = "${var.name_prefix}-alerts" }
}

resource "aws_sns_topic_subscription" "alert_email" {
  count     = var.enable_alarms && var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Hardware or host failure. The recover action moves the instance to
# healthy hardware and keeps its ID, Elastic IP and EBS volumes. "missing"
# keeps the prior state without data, so a stopped instance is not recovered.
resource "aws_cloudwatch_metric_alarm" "system_status_check_failed" {
  count               = var.enable_alarms ? 1 : 0
  alarm_name          = "${var.name_prefix}-system-status-check-failed"
  alarm_description   = "The instance failed its EC2 system status check for 2 minutes; EC2 auto-recover runs."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = aws_instance.this.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = concat(["arn:aws:automate:${var.region}:ec2:recover"], local.alarm_topic)
  ok_actions          = local.alarm_topic
  tags                = { Name = "${var.name_prefix}-system-status-check-failed" }
}

# Guest failure (kernel panic, exhausted memory, broken network): the
# instance is unavailable. Recover does not fix it; reboot the instance.
resource "aws_cloudwatch_metric_alarm" "instance_status_check_failed" {
  count               = var.enable_alarms ? 1 : 0
  alarm_name          = "${var.name_prefix}-instance-status-check-failed"
  alarm_description   = "The instance failed its EC2 instance status check for 5 minutes; reboot it."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  dimensions          = { InstanceId = aws_instance.this.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
  tags                = { Name = "${var.name_prefix}-instance-status-check-failed" }
}

# Sustained CPU. On T-family instances (unlimited mode) this also means
# surplus-credit charges accrue.
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  count               = var.enable_alarms ? 1 : 0
  alarm_name          = "${var.name_prefix}-cpu-high"
  alarm_description   = "The instance averaged over 90% CPU for 15 minutes."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = aws_instance.this.id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 90
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
  tags                = { Name = "${var.name_prefix}-cpu-high" }
}
