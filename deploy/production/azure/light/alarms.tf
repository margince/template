# Basic alerts, always on, with the same thresholds
# as the AWS light stack. The VM has no peer, so these are the signal that
# Margince is down. Azure moves a VM off failed hardware by itself (service
# healing); no recover action is needed.
#
# Receivers: alert_email, or add your own to the action group.

resource "azurerm_monitor_action_group" "alerts" {
  name                = "${var.name_prefix}-alerts"
  resource_group_name = azurerm_resource_group.this.name
  short_name          = substr(replace(var.name_prefix, "-", ""), 0, 12)
  tags                = local.common_tags

  dynamic "email_receiver" {
    for_each = var.alert_email == "" ? [] : [var.alert_email]
    content {
      name                    = "alert-email"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

# VmAvailabilityMetric is 1 while the VM runs and 0 while it is unavailable.
resource "azurerm_monitor_metric_alert" "vm_unavailable" {
  name                = "${var.name_prefix}-vm-unavailable"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [azurerm_linux_virtual_machine.this.id]
  description         = "The VM ${azurerm_linux_virtual_machine.this.name} was unavailable for 5 minutes."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "VmAvailabilityMetric"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 1
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts.id
  }
}

# Sustained CPU. On B-series sizes this also means the CPU credits run out.
resource "azurerm_monitor_metric_alert" "cpu_high" {
  name                = "${var.name_prefix}-cpu-high"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [azurerm_linux_virtual_machine.this.id]
  description         = "The VM ${azurerm_linux_virtual_machine.this.name} averaged over 90% CPU for 15 minutes."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 90
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts.id
  }
}
