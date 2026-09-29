# One Ubuntu 24.04 VM runs everything: nginx (TLS, SPA, reverse proxy),
# margince-api, margince-worker and Redis, all native under systemd. Margince
# is built from source at first boot (modules/vm-config/templates/scripts/margince-build.sh).
#
# Changing anything rendered into custom_data (nginx rules, workspace
# settings, git ref) replaces the VM. The data disk, public IP, Key Vault and
# Postgres stay; the new VM rebuilds and reattaches in about 20 minutes. To
# upgrade Margince without replacing the VM, run `sudo margince-build <ref>`.

module "vm_config" {
  source = "./modules/vm-config"

  key_vault_name             = azurerm_key_vault.this.name
  pg_host                    = azurerm_postgresql_flexible_server.this.fqdn
  public_host                = local.public_host
  public_base_url            = local.public_base_url
  azure_fqdn                 = local.azure_fqdn
  git_url                    = var.margince_git_url
  git_ref                    = var.margince_git_ref
  acme_email                 = var.acme_email
  workspace_name             = var.workspace_name
  workspace_base_currency    = var.workspace_base_currency
  workspace_base_language    = var.workspace_base_language
  workspace_timezone         = var.workspace_timezone
  admin_email                = var.bootstrap_admin_email
  admin_display_name         = var.bootstrap_admin_display_name
  entra_client_id            = local.entra_client_id
  entra_tenant_id            = local.entra_tenant_id
  environment_posture        = var.environment_posture
  include_bootstrap_admin    = var.include_bootstrap_admin
  license_present            = nonsensitive(length(var.license_token) > 0)
  break_glass_cidrs          = var.break_glass_cidrs
  auth_rate_limit_per_minute = var.auth_rate_limit_per_minute
}

locals {
  cloud_init = module.vm_config.cloud_init
  nginx_conf = module.vm_config.nginx_conf
  app_env    = module.vm_config.app_env
  secret_env = module.vm_config.secret_env
  vm_files   = module.vm_config.vm_files
}

resource "azurerm_network_interface" "vm" {
  name                = "${var.name_prefix}-vm"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  name                            = "${var.name_prefix}-vm"
  location                        = azurerm_resource_group.this.location
  resource_group_name             = azurerm_resource_group.this.name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vm.id]
  custom_data                     = base64encode(local.cloud_init)
  tags                            = local.common_tags

  # Trusted Launch (the Canonical server image is Gen2).
  secure_boot_enabled = true
  vtpm_enabled        = true

  # Temp disk and OS/data disk caches encrypted on the host; needs the
  # EncryptionAtHost feature registered on the subscription (README.md).
  encryption_at_host_enabled = var.encryption_at_host

  # Azure-orchestrated guest patching: critical and security updates outside
  # peak hours, reboot only when an update needs one.
  patch_mode            = "AutomaticByPlatform"
  patch_assessment_mode = "AutomaticByPlatform"
  reboot_setting        = "IfRequired"

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.os_disk_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  # Managed boot diagnostics: serial console and boot screenshots.
  boot_diagnostics {}

  # First boot reads the secrets and bootstraps the database, so both must
  # exist. The Key Vault role assignment needs the VM's identity and follows
  # it; margince-setup waits for it to take effect.
  depends_on = [
    azurerm_key_vault_secret.this,
    azurerm_postgresql_flexible_server_configuration.azure_extensions,
    azurerm_postgresql_flexible_server_configuration.require_secure_transport,
    azurerm_postgresql_flexible_server_configuration.ssl_min_protocol_version,
    azurerm_postgresql_flexible_server_configuration.connection_throttle,
  ]

  lifecycle {
    precondition {
      condition     = length(base64encode(local.cloud_init)) <= 65535
      error_message = "custom_data exceeds Azure's 64 KB limit."
    }
  }
}

resource "azurerm_managed_disk" "data" {
  name                 = "${var.name_prefix}-data"
  location             = azurerm_resource_group.this.location
  resource_group_name  = azurerm_resource_group.this.name
  storage_account_type = var.data_disk_type
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_gb
  tags                 = local.common_tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_linux_virtual_machine.this.id
  lun                = 0
  caching            = "None"
}
