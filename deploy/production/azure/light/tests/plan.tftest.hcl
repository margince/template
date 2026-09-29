# Offline checks with mocked providers: no Azure or Entra access needed.
#   terraform init -backend=false && terraform test
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000001"
      object_id = "00000000-0000-0000-0000-000000000002"
    }
  }

  # Resource IDs in the shape the provider validates, for the mocked apply.
  mock_resource "azurerm_virtual_network" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Network/virtualNetworks/vnet" }
  }
  mock_resource "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Network/virtualNetworks/vnet/subnets/subnet" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Network/networkSecurityGroups/nsg" }
  }
  mock_resource "azurerm_public_ip" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Network/publicIPAddresses/pip", ip_address = "198.51.100.7" }
  }
  mock_resource "azurerm_network_interface" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Network/networkInterfaces/nic" }
  }
  mock_resource "azurerm_private_dns_zone" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Network/privateDnsZones/margince.postgres.database.azure.com" }
  }
  mock_resource "azurerm_linux_virtual_machine" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Compute/virtualMachines/vm"
      identity = { principal_id = "00000000-0000-0000-0000-000000000004", tenant_id = "00000000-0000-0000-0000-000000000001" }
    }
  }
  mock_resource "azurerm_managed_disk" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Compute/disks/data" }
  }
  mock_resource "azurerm_key_vault" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.KeyVault/vaults/kv" }
  }
  mock_resource "azurerm_recovery_services_vault" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.RecoveryServices/vaults/rsv" }
  }
  mock_resource "azurerm_backup_policy_vm" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.RecoveryServices/vaults/rsv/backupPolicies/daily" }
  }
  mock_resource "azurerm_postgresql_flexible_server" {
    defaults = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.DBforPostgreSQL/flexibleServers/db"
      fqdn = "margince-abcde-db.postgres.database.azure.com"
    }
  }
}
mock_provider "azuread" {
  mock_data "azuread_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000001"
      object_id = "00000000-0000-0000-0000-000000000002"
    }
  }
  mock_data "azuread_application_published_app_ids" {
    defaults = {
      result = { MicrosoftGraph = "00000003-0000-0000-c000-000000000000" }
    }
  }
  mock_data "azuread_service_principal" {
    defaults = {
      # Microsoft Graph's published delegated-permission ids, identical in every
      # tenant. Not credentials; gitleaks' generic-api-key rule matches their shape.
      oauth2_permission_scope_ids = {
        openid      = "37f7f235-527c-4136-accd-4a02d197296e", email = "64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0",
        profile     = "14dad69e-099b-42c9-810b-d002981feec1", offline_access = "7427e0e9-2fba-42fe-b0c0-848c9e6a8182", # gitleaks:allow
        "User.Read" = "e1fe6dd8-ba31-4d61-89e7-88639da4683d", "Mail.Read" = "570282fd-fa5c-430d-a7fd-fc8dc98a9dca",
        "Mail.Send" = "e383f46e-2787-4529-855e-0e479a3ffac0", "Calendars.Read" = "465a38f9-76ea-45b9-9f34-9e8b0d4b0b42"
      }
    }
  }

  mock_resource "azuread_application" {
    defaults = {
      id        = "/applications/00000000-0000-0000-0000-000000000005"
      client_id = "00000000-0000-0000-0000-000000000006"
    }
  }
  mock_resource "azuread_application_password" {
    defaults = { end_date = "2027-06-01T00:00:00Z" }
  }
  mock_resource "azuread_service_principal" {
    defaults = { object_id = "00000000-0000-0000-0000-000000000007" }
  }
}
mock_provider "random" {}
mock_provider "time" {}

variables {
  bootstrap_admin_email        = "admin@example.com"
  license_token                = "test-licence"
  entra_access_group_object_id = "00000000-0000-0000-0000-0000000000aa"
  admin_ssh_public_key         = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC/vUmkEV7lfFP7t36rOoMbvwoNzx4r0gfQKltPmyKTIC6WILJaitH79JH2yJXHb8ePibRalweus+EV/EPKn0oUrOzjVsjVzMef9Rz5CoAovRnDe6z2+y84XnjlIeN5b58NkeBaliOlFv36enIfMluv/sOMHTjfBwbCooF+ChwYnz9p20V5y0DFe/axStpcKcmHW7RfRuijO+vxC+te9mhCbLdN1sJm6qC9pSeADHSDH/swyDK6l1526/+NJqHfryRbhuQ8uPDL7pT14Z02AFnvIMvYhvSomi4Kag9aFQLFmm2Jd1Yz6lERFj4i6+51WvD/ZPmC7OER6N09qlUdXo3qx8Amf472GAQl9VhVHtolycBNtKehQomHLNuBffSIiarnOH5hYwLQEBD3ixah4xbXlmDAb9p+Ub31ppEv9ZLA2YebcRPzUfy/bvBLxysWAJTSwrnTvP0/bJW4Egqa37prx8MQRQkB/yRiET3I3DHFlLDsSnKQnEYSEBmvvLvxE6s= test"
  break_glass_cidrs            = ["203.0.113.10/32"]
  operator_ip_allowlist        = ["203.0.113.20"]
}

run "first_plan" {
  command = plan
  assert {
    condition     = length(azurerm_bastion_host.developer) == 1
    error_message = "Bastion Developer is on by default."
  }
  assert {
    condition     = contains(keys(local.kv_secrets), "margince-license") && local.secret_env["MARGINCE_LICENSE"] == "margince-license"
    error_message = "A licence token is stored and passed to the services."
  }
  assert {
    condition     = local.app_env["MARGINCE_REDIS"] == "127.0.0.1:6379" && local.app_env["MARGINCE_TRUSTED_PROXIES"] == "127.0.0.1/32" && !contains(keys(local.app_env), "MARGINCE_ENV")
    error_message = "Loopback Redis, trusted loopback proxy, production posture."
  }
  assert {
    condition     = azurerm_postgresql_flexible_server.this.public_network_access_enabled == false && azurerm_postgresql_flexible_server.this.sku_name == "B_Standard_B1ms"
    error_message = "Postgres is VNet-only and on the cheapest SKU."
  }
}

run "platform_hardening" {
  command = plan
  assert {
    condition     = azurerm_linux_virtual_machine.this.secure_boot_enabled && azurerm_linux_virtual_machine.this.vtpm_enabled && azurerm_linux_virtual_machine.this.encryption_at_host_enabled
    error_message = "Trusted Launch and encryption at host are on."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.patch_mode == "AutomaticByPlatform" && azurerm_linux_virtual_machine.this.reboot_setting == "IfRequired"
    error_message = "Azure orchestrates guest patching."
  }
  assert {
    condition     = azurerm_key_vault.this.rbac_authorization_enabled && azurerm_key_vault.this.network_acls[0].default_action == "Deny"
    error_message = "Key Vault is RBAC-only and its firewall denies by default."
  }
  assert {
    condition     = azurerm_postgresql_flexible_server.this.auto_grow_enabled && azurerm_postgresql_flexible_server_configuration.connection_throttle.value == "on" && azurerm_postgresql_flexible_server_configuration.ssl_min_protocol_version.value == "TLSv1.2"
    error_message = "Postgres auto-grows storage, throttles failed logins and requires TLS 1.2+."
  }
  assert {
    condition     = length(azurerm_recovery_services_vault.this) == 1
    error_message = "VM backup is on by default: the data disk has no other copy."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.admin_username != "margince"
    error_message = "The SSH admin is not the service user margince."
  }
}

run "admin_cannot_be_service_user" {
  command = plan
  variables {
    admin_username = "margince"
  }
  expect_failures = [var.admin_username]
}

run "vm_backup" {
  command = plan
  variables {
    enable_vm_backup = true
  }
  assert {
    condition     = azurerm_backup_policy_vm.daily[0].policy_type == "V2" && azurerm_backup_policy_vm.daily[0].retention_daily[0].count == 7
    error_message = "Trusted Launch needs an Enhanced (V2) policy; daily, 7 days."
  }
  assert {
    condition     = length(azurerm_backup_protected_vm.this) == 1
    error_message = "The VM is protected."
  }
}

run "empty_operator_allowlist_is_refused" {
  command = plan
  variables {
    operator_ip_allowlist = []
  }
  expect_failures = [var.operator_ip_allowlist]
}

run "nginx_renders_break_glass_rule" {
  command = plan
  assert {
    condition     = strcontains(local.nginx_conf, "203.0.113.10/32 1;") && strcontains(local.nginx_conf, "if ($block_password_login) { return 403; }")
    error_message = "Password login is limited to break_glass_cidrs."
  }
  assert {
    condition     = strcontains(local.nginx_conf, "location = /metrics { return 404; }") && strcontains(local.nginx_conf, "proxy_set_header X-Forwarded-For $remote_addr;")
    error_message = "/metrics is hidden and X-Forwarded-For is overwritten."
  }
  assert {
    condition     = strcontains(local.nginx_conf, "rate=30r/m")
    error_message = "Auth paths are rate limited."
  }
  assert {
    condition     = strcontains(local.nginx_conf, "ssl_protocols TLSv1.2 TLSv1.3;") && strcontains(local.nginx_conf, "ssl_session_tickets off;") && strcontains(local.nginx_conf, "ECDHE-ECDSA-AES128-GCM-SHA256:")
    error_message = "TLS follows Mozilla intermediate."
  }
}

run "custom_hostname" {
  command = plan
  variables {
    public_hostname = "crm.example.com"
  }
  assert {
    condition     = local.public_base_url == "https://crm.example.com" && contains(local.entra_redirect_uris, "https://crm.example.com/v1/auth/oidc/microsoft/callback")
    error_message = "public_hostname drives the base URL and the Entra redirect URIs."
  }
}

run "production_without_licence_is_refused" {
  command = plan
  variables {
    license_token = ""
  }
  expect_failures = [terraform_data.posture]
}

run "development_posture_boots_unlicensed" {
  command = plan
  variables {
    license_token       = ""
    environment_posture = "development"
  }
  assert {
    condition     = local.app_env["MARGINCE_ENV"] == "dev" && !contains(keys(local.kv_secrets), "margince-license")
    error_message = "Development posture sets MARGINCE_ENV=dev and stores no empty licence."
  }
}

run "ed25519_key_is_accepted" {
  command = plan
  variables {
    admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test"
  }
}

run "ecdsa_key_is_refused" {
  command = plan
  variables {
    admin_ssh_public_key = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTY= test"
  }
  expect_failures = [var.admin_ssh_public_key]
}

# Mocked apply, so every value is known: custom_data stays under Azure's
# 64 KB limit.
run "custom_data_fits" {
  command = apply
  assert {
    condition     = length(base64encode(local.cloud_init)) < 65535
    error_message = "custom_data exceeds 64 KB."
  }
  assert {
    condition     = length(yamldecode(local.cloud_init).write_files) == length(local.vm_files)
    error_message = "cloud-init renders as valid YAML with every file."
  }
  assert {
    condition     = azurerm_key_vault.this.network_acls[0].ip_rules == toset(["203.0.113.20", "198.51.100.7"])
    error_message = "Only the operators and the VM's public IP pass the Key Vault firewall."
  }
}
