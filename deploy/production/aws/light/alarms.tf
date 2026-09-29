# One alarm per instance — the thing "light" actually needs watched: each
# single instance's own status checks, since none has a peer to fail over
# to. No CPU-credit-balance alarms the way the full stack's alarms.tf
# carries — this is the light/small-deployment option, and one signal per
# box that "it is down" is the honest floor.
#
# Gated on var.enable_deep_monitoring, same reasoning as the full stack: no
# operator alert destination is picked on your own behalf. Subscribe with:
#   aws sns subscribe --topic-arn "$(terraform output -raw alerts_topic_arn)" \
#     --protocol email --notification-endpoint you@example.com

resource "aws_sns_topic" "alerts" {
  count = var.enable_deep_monitoring ? 1 : 0
  name  = "${var.name_prefix}-alerts"
  tags  = { Name = "${var.name_prefix}-alerts", Component = "observability" }
}

resource "aws_cloudwatch_metric_alarm" "instance_status_check_failed" {
  for_each = var.enable_deep_monitoring ? {
    edge   = aws_instance.edge.id
    app    = aws_instance.app.id
    worker = aws_instance.worker.id
  } : {}

  alarm_name          = "${var.name_prefix}-${each.key}-status-check-failed"
  alarm_description   = "EC2 instance ${each.value} (${each.key}) is failing its own status checks - the single point of failure this stack accepts for that role, so this is the one signal that it is down."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alerts[0].arn]
  ok_actions    = [aws_sns_topic.alerts[0].arn]

  tags = { Name = "${var.name_prefix}-${each.key}-status-check-failed", Component = "observability" }
}
