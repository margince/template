# Baseline alerting, on by default (var.enable_alarms). Every alarm pages the
# same CMK-encrypted SNS topic, on ALARM and on OK. kms.tf's
# AllowCloudWatchAlarmsToSNS statement is what lets CloudWatch publish to a
# topic under that key; without it every notification is silently dropped.
#
# Subscription: var.alert_email creates an email subscription (AWS mails a
# confirmation link; nothing is delivered until it is clicked). For Slack,
# PagerDuty or anything else, subscribe your own endpoint:
#   aws sns subscribe --topic-arn "$(terraform output -raw alerts_topic_arn)" \
#     --protocol email --notification-endpoint you@example.com
#
# treat_missing_data: "notBreaching" for traffic- or load-driven metrics
# (no requests means no 5xx, no latency datapoint, nothing to page about);
# "breaching" for RDS storage and CPU credits, where a missing datapoint means
# the instance itself stopped reporting.
#
# Thresholds are starting points, not tuned values; revisit once real traffic
# exists (same reasoning as the instance sizing).

locals {
  alarms_on     = var.enable_alarms
  alarm_actions = local.alarms_on ? [aws_sns_topic.alerts[0].arn] : []

  # The one place this number is spelled; elasticache.tf's
  # num_cache_clusters reads it too, so the replication group's actual node
  # count and the per-node alarms below can never silently disagree.
  redis_node_count = 2

  # ElastiCache assigns member node IDs "<replication_group_id>-001".."-00N"
  # when num_cache_clusters is set; per-node metrics are keyed on that.
  redis_node_ids = [
    for i in range(local.redis_node_count) :
    "${aws_elasticache_replication_group.this.replication_group_id}-${format("%03d", i + 1)}"
  ]

  # CPU-credit alarms only mean something on burstable (T-family) classes.
  rds_is_burstable   = startswith(var.db_instance_class, "db.t")
  redis_is_burstable = startswith(var.redis_node_type, "cache.t")

  ecs_services = {
    api    = aws_ecs_service.api.name
    worker = aws_ecs_service.worker.name
    web    = aws_ecs_service.web.name
  }

  alb_target_groups = {
    api = aws_lb_target_group.api.arn_suffix
    web = aws_lb_target_group.web.arn_suffix
  }

  # 5 percent of the initial allocation, in bytes. rds.tf enables storage
  # autoscaling, which grows the volume once free space drops under 10
  # percent, so this only fires when autoscaling could not keep up or hit
  # max_allocated_storage.
  rds_free_storage_threshold_bytes = max(1, var.db_allocated_storage_gb * 0.05) * 1024 * 1024 * 1024
}

resource "aws_sns_topic" "alerts" {
  count             = local.alarms_on ? 1 : 0
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = aws_kms_key.data.arn
  tags              = { Name = "${var.name_prefix}-alerts", Component = "observability" }
}

resource "aws_sns_topic_subscription" "alert_email" {
  count     = local.alarms_on && var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---- ALB ---------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "alb_elb_5xx" {
  count               = local.alarms_on ? 1 : 0
  alarm_name          = "${var.name_prefix}-alb-elb-5xx"
  alarm_description   = "The ALB itself returned more than ${var.alarm_alb_5xx_threshold} 5xx responses in 5 minutes (no healthy target, target connection errors, ALB limits)."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.this.arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.alarm_alb_5xx_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-alb-elb-5xx", Component = "observability" }
}

resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  count               = local.alarms_on ? 1 : 0
  alarm_name          = "${var.name_prefix}-alb-target-5xx"
  alarm_description   = "api/web targets returned more than ${var.alarm_alb_5xx_threshold} 5xx responses in 5 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.this.arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.alarm_alb_5xx_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-alb-target-5xx", Component = "observability" }
}

# Three consecutive minutes, so a task being replaced during a rolling
# deploy does not page on its own.
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  for_each            = local.alarms_on ? local.alb_target_groups : {}
  alarm_name          = "${var.name_prefix}-alb-unhealthy-${each.key}"
  alarm_description   = "At least one ${each.key} target has been failing ALB health checks for 3 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.this.arn_suffix, TargetGroup = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-alb-unhealthy-${each.key}", Component = "observability" }
}

resource "aws_cloudwatch_metric_alarm" "alb_p95_latency" {
  count               = local.alarms_on ? 1 : 0
  alarm_name          = "${var.name_prefix}-alb-p95-latency"
  alarm_description   = "ALB TargetResponseTime p95 above ${var.alarm_alb_p95_latency_seconds}s for 15 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = aws_lb.this.arn_suffix }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.alarm_alb_p95_latency_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-alb-p95-latency", Component = "observability" }
}

# ---- ECS -----------------------------------------------------------------------
# api and worker autoscale on CPU at 70 percent (ecs.tf); sustained 85
# percent means the autoscaler is already at its max count, or (web) that the
# fixed desired_count is too small.

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  for_each            = local.alarms_on ? local.ecs_services : {}
  alarm_name          = "${var.name_prefix}-ecs-${each.key}-cpu-high"
  alarm_description   = "ECS service ${each.value} average CPU above 85 percent for 15 minutes."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = aws_ecs_cluster.this.name, ServiceName = each.value }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-ecs-${each.key}-cpu", Component = "observability" }
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  for_each            = local.alarms_on ? local.ecs_services : {}
  alarm_name          = "${var.name_prefix}-ecs-${each.key}-memory-high"
  alarm_description   = "ECS service ${each.value} average memory above 85 percent for 15 minutes; tasks are close to being OOM-killed."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  dimensions          = { ClusterName = aws_ecs_cluster.this.name, ServiceName = each.value }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-ecs-${each.key}-memory", Component = "observability" }
}

# ---- RDS ---------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  count               = local.alarms_on ? 1 : 0
  alarm_name          = "${var.name_prefix}-rds-free-storage-low"
  alarm_description   = "RDS ${aws_db_instance.this.identifier} free storage below 5 percent of the initial allocation; storage autoscaling did not keep up or reached max_allocated_storage."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = local.rds_free_storage_threshold_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-rds-free-storage", Component = "observability" }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count               = local.alarms_on ? 1 : 0
  alarm_name          = "${var.name_prefix}-rds-cpu-high"
  alarm_description   = "RDS ${aws_db_instance.this.identifier} average CPU above 85 percent for 15 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-rds-cpu", Component = "observability" }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  count               = local.alarms_on ? 1 : 0
  alarm_name          = "${var.name_prefix}-rds-connections-high"
  alarm_description   = "RDS ${aws_db_instance.this.identifier} has more than ${var.alarm_rds_max_connections} connections; close to max_connections."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.alarm_rds_max_connections
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-rds-connections", Component = "observability" }
}

# Burstable classes accumulate credits at idle and throttle under SUSTAINED
# load once the balance is exhausted; that shows up as "the app got slow"
# with nothing else obviously wrong. This fires BEFORE the throttling does.
resource "aws_cloudwatch_metric_alarm" "rds_cpu_credit_balance" {
  count               = local.alarms_on && local.rds_is_burstable ? 1 : 0
  alarm_name          = "${var.name_prefix}-rds-cpu-credit-balance-low"
  alarm_description   = "RDS ${aws_db_instance.this.identifier} is burning through its CPU credit balance; sustained load is about to throttle it."
  namespace           = "AWS/RDS"
  metric_name         = "CPUCreditBalance"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 20
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-rds-cpu-credit-balance", Component = "observability" }
}

# ---- ElastiCache (per node: these metrics are keyed on CacheClusterId) ------

resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  count               = local.alarms_on ? local.redis_node_count : 0
  alarm_name          = "${var.name_prefix}-redis-memory-high-${count.index + 1}"
  alarm_description   = "ElastiCache node ${local.redis_node_ids[count.index]} DatabaseMemoryUsagePercentage above 80 percent; evictions or write failures are next."
  namespace           = "AWS/ElastiCache"
  metric_name         = "DatabaseMemoryUsagePercentage"
  dimensions          = { CacheClusterId = local.redis_node_ids[count.index] }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-redis-memory-${count.index + 1}", Component = "observability" }
}

resource "aws_cloudwatch_metric_alarm" "redis_engine_cpu" {
  count               = local.alarms_on ? local.redis_node_count : 0
  alarm_name          = "${var.name_prefix}-redis-engine-cpu-high-${count.index + 1}"
  alarm_description   = "ElastiCache node ${local.redis_node_ids[count.index]} EngineCPUUtilization above 80 percent for 15 minutes."
  namespace           = "AWS/ElastiCache"
  metric_name         = "EngineCPUUtilization"
  dimensions          = { CacheClusterId = local.redis_node_ids[count.index] }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-redis-engine-cpu-${count.index + 1}", Component = "observability" }
}

resource "aws_cloudwatch_metric_alarm" "redis_cpu_credit_balance" {
  count               = local.alarms_on && local.redis_is_burstable ? local.redis_node_count : 0
  alarm_name          = "${var.name_prefix}-redis-cpu-credit-balance-low-${count.index + 1}"
  alarm_description   = "ElastiCache node ${local.redis_node_ids[count.index]} is burning through its CPU credit balance."
  namespace           = "AWS/ElastiCache"
  metric_name         = "CPUCreditBalance"
  dimensions          = { CacheClusterId = local.redis_node_ids[count.index] }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 20
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-redis-cpu-credit-balance-${count.index + 1}", Component = "observability" }
}

# ---- WAF ---------------------------------------------------------------------
# Rule = "ALL" is the web-ACL-wide aggregate. In waf_mode = "count" nothing is
# blocked, so this alarm stays quiet until the switch to "block"; during the
# count phase, watch CountedRequests and the WAF log group instead.

resource "aws_cloudwatch_metric_alarm" "waf_blocked_requests" {
  count               = local.alarms_on ? 1 : 0
  alarm_name          = "${var.name_prefix}-waf-blocked-requests-spike"
  alarm_description   = "WAF blocked more than ${var.alarm_waf_blocked_requests_threshold} requests in 5 minutes: an attack, or a false positive locking real users out. Check the aws-waf-logs-${var.name_prefix} log group."
  namespace           = "AWS/WAFV2"
  metric_name         = "BlockedRequests"
  dimensions          = { WebACL = aws_wafv2_web_acl.alb.name, Region = var.aws_region, Rule = "ALL" }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.alarm_waf_blocked_requests_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = { Name = "${var.name_prefix}-waf-blocked-requests", Component = "observability" }
}
