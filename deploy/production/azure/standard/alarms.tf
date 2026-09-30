# Metric alerts for the data services, the two apps and the WAF. Thresholds are
# starting points, not tuned values.
#
# The only notification wired is var.alert_email. Any other alert
# destination is the operator's to own.

locals {
  # One entry per metric alert. dimension is "name=value", or "" for none.
  metric_alerts = merge(
    {
      postgres-cpu-high = {
        scope       = azurerm_postgresql_flexible_server.this.id
        namespace   = "Microsoft.DBforPostgreSQL/flexibleServers"
        metric      = "cpu_percent"
        aggregation = "Average"
        operator    = "GreaterThan"
        threshold   = 80
        window      = "PT15M"
        description = "Postgres is sustaining high CPU."
        dimension   = ""
      }
      postgres-storage-high = {
        scope       = azurerm_postgresql_flexible_server.this.id
        namespace   = "Microsoft.DBforPostgreSQL/flexibleServers"
        metric      = "storage_percent"
        aggregation = "Average"
        operator    = "GreaterThan"
        threshold   = 85
        window      = "PT15M"
        description = "Postgres storage is above 85%. Auto-grow extends it, but check growth."
        dimension   = ""
      }
      redis-restarts = {
        scope       = azurerm_container_app.redis.id
        namespace   = "Microsoft.App/containerApps"
        metric      = "RestartCount"
        aggregation = "Total"
        operator    = "GreaterThan"
        threshold   = 2
        window      = "PT15M"
        description = "The Redis container is restarting (OOM, failed probe or AOF load error)."
        dimension   = ""
      }
    },
    # Burstable SKUs throttle to their baseline once CPU credits run out.
    startswith(var.db_sku_name, "B_") ? {
      postgres-cpu-credits-low = {
        scope       = azurerm_postgresql_flexible_server.this.id
        namespace   = "Microsoft.DBforPostgreSQL/flexibleServers"
        metric      = "cpu_credits_remaining"
        aggregation = "Minimum"
        operator    = "LessThan"
        threshold   = 30
        window      = "PT15M"
        description = "Postgres Burstable CPU credits are nearly used up; the server will throttle to its baseline."
        dimension   = ""
      }
    } : {},
    var.deploy_apps ? {
      api-5xx = {
        scope       = azurerm_container_app.api[0].id
        namespace   = "Microsoft.App/containerApps"
        metric      = "Requests"
        aggregation = "Total"
        operator    = "GreaterThan"
        threshold   = 10
        window      = "PT5M"
        description = "The api app is returning 5xx responses."
        dimension   = "statusCodeCategory=5xx"
      }
      api-restarts = {
        scope       = azurerm_container_app.api[0].id
        namespace   = "Microsoft.App/containerApps"
        metric      = "RestartCount"
        aggregation = "Total"
        operator    = "GreaterThan"
        threshold   = 3
        window      = "PT15M"
        description = "api replicas are restarting."
        dimension   = ""
      }
      # Requests the WAF blocked (custom and managed rules). Only meaningful
      # once waf_mode = "block"; in count mode nothing is blocked. The
      # counterpart of the AWS stack's WAF BlockedRequests alarm.
      waf-blocked-requests = {
        scope       = azurerm_application_gateway.this[0].id
        namespace   = "Microsoft.Network/applicationGateways"
        metric      = "AzwafTotalRequests"
        aggregation = "Total"
        operator    = "GreaterThan"
        threshold   = 500
        window      = "PT5M"
        description = "The WAF is blocking an unusual number of requests: an attack, or a false positive after a release."
        dimension   = "Action=Block"
      }
      appgw-unhealthy-backend = {
        scope       = azurerm_application_gateway.this[0].id
        namespace   = "Microsoft.Network/applicationGateways"
        metric      = "UnhealthyHostCount"
        aggregation = "Average"
        operator    = "GreaterThan"
        threshold   = 0
        window      = "PT5M"
        description = "The Application Gateway cannot reach the api app (/healthz probe failing)."
        dimension   = ""
      }
      worker-restarts = {
        scope       = azurerm_container_app.worker[0].id
        namespace   = "Microsoft.App/containerApps"
        metric      = "RestartCount"
        aggregation = "Total"
        operator    = "GreaterThan"
        threshold   = 3
        window      = "PT15M"
        description = "worker replicas are restarting."
        dimension   = ""
      }
    } : {},
  )
}

resource "azurerm_monitor_action_group" "alerts" {
  name                = "${var.name_prefix}-alerts"
  resource_group_name = azurerm_resource_group.this.name
  short_name          = substr(var.name_prefix, 0, 12)

  dynamic "email_receiver" {
    for_each = var.alert_email != "" ? [var.alert_email] : []
    content {
      name          = "operator"
      email_address = email_receiver.value
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-alerts", Component = "observability" })
}

resource "azurerm_monitor_metric_alert" "this" {
  for_each            = local.metric_alerts
  name                = "${var.name_prefix}-${each.key}"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [each.value.scope]
  description         = each.value.description
  severity            = 2
  frequency           = "PT5M"
  window_size         = each.value.window

  criteria {
    metric_namespace = each.value.namespace
    metric_name      = each.value.metric
    aggregation      = each.value.aggregation
    operator         = each.value.operator
    threshold        = each.value.threshold

    dynamic "dimension" {
      for_each = each.value.dimension == "" ? [] : [split("=", each.value.dimension)]
      content {
        name     = dimension.value[0]
        operator = "Include"
        values   = [dimension.value[1]]
      }
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts.id
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${each.key}", Component = "observability" })
}
