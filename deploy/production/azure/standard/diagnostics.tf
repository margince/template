# Diagnostic settings for the resources without one next to their own
# definition (Postgres, Key Vault and the file service have theirs in
# their own files), the Application Gateway included. Everything goes to the shared Log Analytics workspace.
locals {
  nsg_logs = ["NetworkSecurityGroupEvent", "NetworkSecurityGroupRuleCounter"]

  diagnostic_settings = merge(
    {
      nsg-containerapps     = { id = azurerm_network_security_group.containerapps.id, logs = local.nsg_logs, metrics = false, dedicated = false }
      nsg-postgres          = { id = azurerm_network_security_group.postgres.id, logs = local.nsg_logs, metrics = false, dedicated = false }
      nsg-private-endpoints = { id = azurerm_network_security_group.private_endpoints.id, logs = local.nsg_logs, metrics = false, dedicated = false }
      nsg-appgw             = { id = azurerm_network_security_group.appgw.id, logs = local.nsg_logs, metrics = false, dedicated = false }
      nsg-ops               = { id = azurerm_network_security_group.ops.id, logs = local.nsg_logs, metrics = false, dedicated = false }
      acr = {
        id        = azurerm_container_registry.this.id
        logs      = ["ContainerRegistryLoginEvents", "ContainerRegistryRepositoryEvents"]
        metrics   = true
        dedicated = false
      }
      blob-audit = {
        id        = "${azurerm_storage_account.this.id}/blobServices/default"
        logs      = ["StorageRead", "StorageWrite", "StorageDelete"]
        metrics   = false
        dedicated = false
      }
      # Azure Backup's resource-specific tables need the Dedicated destination.
      rsv = {
        id = azurerm_recovery_services_vault.this.id
        logs = ["CoreAzureBackup", "AddonAzureBackupJobs", "AddonAzureBackupAlerts", "AddonAzureBackupPolicy",
        "AddonAzureBackupStorage", "AddonAzureBackupProtectedInstance"]
        metrics   = false
        dedicated = true
      }
    },
    # The gateway's WAF and access logs, into the resource-specific tables
    # AGWFirewallLogs and AGWAccessLogs (retention: appgw.tf).
    var.deploy_apps ? {
      appgw = {
        id        = azurerm_application_gateway.this[0].id
        logs      = ["ApplicationGatewayFirewallLog", "ApplicationGatewayAccessLog"]
        metrics   = true
        dedicated = true
      }
    } : {},
  )
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  for_each                       = local.diagnostic_settings
  name                           = "${var.name_prefix}-${each.key}"
  target_resource_id             = each.value.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = each.value.dedicated ? "Dedicated" : null

  dynamic "enabled_log" {
    for_each = each.value.logs
    content {
      category = enabled_log.value
    }
  }

  dynamic "enabled_metric" {
    for_each = each.value.metrics ? ["AllMetrics"] : []
    content {
      category = enabled_metric.value
    }
  }
}
