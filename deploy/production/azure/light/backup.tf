# Optional Azure Backup of the VM (OS and data disk). Trusted Launch VMs need
# the Enhanced (V2) policy. Azure keeps deleted backup data recoverable for 14
# days (soft delete is always on), which delays deleting the vault.

resource "azurerm_recovery_services_vault" "this" {
  count               = var.enable_vm_backup ? 1 : 0
  name                = "${var.name_prefix}-rsv"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard"
  storage_mode_type   = "LocallyRedundant"
  tags                = local.common_tags
}

resource "azurerm_backup_policy_vm" "daily" {
  count               = var.enable_vm_backup ? 1 : 0
  name                = "${var.name_prefix}-daily"
  resource_group_name = azurerm_resource_group.this.name
  recovery_vault_name = azurerm_recovery_services_vault.this[0].name
  policy_type         = "V2"
  timezone            = "UTC"

  instant_restore_retention_days = 2

  backup {
    frequency = "Daily"
    time      = "02:00"
  }

  retention_daily {
    count = 7
  }
}

resource "azurerm_backup_protected_vm" "this" {
  count               = var.enable_vm_backup ? 1 : 0
  resource_group_name = azurerm_resource_group.this.name
  recovery_vault_name = azurerm_recovery_services_vault.this[0].name
  source_vm_id        = azurerm_linux_virtual_machine.this.id
  backup_policy_id    = azurerm_backup_policy_vm.daily[0].id

  # The data disk is part of the backup.
  depends_on = [azurerm_virtual_machine_data_disk_attachment.data]
}
