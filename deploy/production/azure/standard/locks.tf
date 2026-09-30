# CanNotDelete locks on the stateful resources: they block deletes from the
# portal, CLI and Terraform alike, but not updates or data-plane access.
# Set enable_resource_locks = false and apply before `terraform destroy`.
locals {
  locked_resources = {
    postgres = azurerm_postgresql_flexible_server.this.id
    storage  = azurerm_storage_account.this.id
    keyvault = azurerm_key_vault.this.id
    acr      = azurerm_container_registry.this.id
    rsv      = azurerm_recovery_services_vault.this.id
  }
}

resource "azurerm_management_lock" "this" {
  for_each   = var.enable_resource_locks ? local.locked_resources : {}
  name       = "${var.name_prefix}-${each.key}-cannot-delete"
  scope      = each.value
  lock_level = "CanNotDelete"
  notes      = "Managed by Terraform (enable_resource_locks). Remove before destroying the stack."
}
