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
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light" }
  }
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
  mock_resource "azurerm_linux_virtual_machine" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Compute/virtualMachines/vm" }
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
  mock_resource "azurerm_monitor_action_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Insights/actionGroups/alerts" }
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
  domain                       = "crm.example.com"
  license_token                = "test-licence"
  entra_access_group_object_id = "00000000-0000-0000-0000-0000000000aa"
  admin_ssh_public_key         = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC/vUmkEV7lfFP7t36rOoMbvwoNzx4r0gfQKltPmyKTIC6WILJaitH79JH2yJXHb8ePibRalweus+EV/EPKn0oUrOzjVsjVzMef9Rz5CoAovRnDe6z2+y84XnjlIeN5b58NkeBaliOlFv36enIfMluv/sOMHTjfBwbCooF+ChwYnz9p20V5y0DFe/axStpcKcmHW7RfRuijO+vxC+te9mhCbLdN1sJm6qC9pSeADHSDH/swyDK6l1526/+NJqHfryRbhuQ8uPDL7pT14Z02AFnvIMvYhvSomi4Kag9aFQLFmm2Jd1Yz6lERFj4i6+51WvD/ZPmC7OER6N09qlUdXo3qx8Amf472GAQl9VhVHtolycBNtKehQomHLNuBffSIiarnOH5hYwLQEBD3ixah4xbXlmDAb9p+Ub31ppEv9ZLA2YebcRPzUfy/bvBLxysWAJTSwrnTvP0/bJW4Egqa37prx8MQRQkB/yRiET3I3DHFlLDsSnKQnEYSEBmvvLvxE6s= test"
  ssh_allowed_cidrs            = ["203.0.113.10/32", "198.51.100.0/24"]
}

run "single_ubuntu_vm" {
  command = plan
  assert {
    condition = (
      azurerm_linux_virtual_machine.this.source_image_reference[0].publisher == "Canonical" &&
      azurerm_linux_virtual_machine.this.source_image_reference[0].offer == "ubuntu-24_04-lts" &&
      azurerm_linux_virtual_machine.this.source_image_reference[0].sku == "server"
    )
    error_message = "The VM runs Canonical Ubuntu 24.04 LTS server."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.size == "Standard_B2ms" && azurerm_linux_virtual_machine.this.admin_username == "azureadmin" && azurerm_linux_virtual_machine.this.disable_password_authentication
    error_message = "One Standard_B2ms VM, admin user azureadmin, key login only."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.secure_boot_enabled && azurerm_linux_virtual_machine.this.vtpm_enabled && azurerm_linux_virtual_machine.this.encryption_at_host_enabled
    error_message = "Trusted Launch and encryption at host are on."
  }
  assert {
    condition     = azurerm_public_ip.vm.allocation_method == "Static" && azurerm_public_ip.vm.sku == "Standard"
    error_message = "The public IP is static."
  }
}

run "firewall" {
  command = plan
  assert {
    condition = one([
      for r in azurerm_network_security_group.vm.security_rule : r
      if r.access == "Allow" && r.destination_port_range == "22"
    ]).source_address_prefixes == toset(["203.0.113.10/32", "198.51.100.0/24"])
    error_message = "SSH is allowed from ssh_allowed_cidrs only."
  }
  assert {
    condition = one([
      for r in azurerm_network_security_group.vm.security_rule : r
      if r.name == "AllowHttpHttpsFromInternet"
    ]).destination_port_ranges == toset(["80", "443"]) && one([for r in azurerm_network_security_group.vm.security_rule : r if r.name == "AllowHttpHttpsFromInternet"]).source_address_prefix == "Internet"
    error_message = "80 and 443 are open to the internet."
  }
  assert {
    condition     = anytrue([for r in azurerm_network_security_group.vm.security_rule : r.access == "Deny" && r.destination_port_range == "22" && r.source_address_prefix == "*"])
    error_message = "Every other SSH source is denied."
  }
  assert {
    condition     = azurerm_key_vault.this.network_acls[0].default_action == "Deny" && toset(azurerm_key_vault.this.network_acls[0].ip_rules) == toset(["203.0.113.10", "198.51.100.0/24"])
    error_message = "The Key Vault firewall admits ssh_allowed_cidrs only, /32 as a single address."
  }
}

run "data_disk" {
  command = plan
  assert {
    condition     = azurerm_managed_disk.data.disk_size_gb == 64 && azurerm_virtual_machine_data_disk_attachment.data.lun == 0
    error_message = "A 64 GB data disk on LUN 0."
  }
  assert {
    condition     = strcontains(regex("resource \"azurerm_managed_disk\" \"data\" \\{((?s:.*?))\\n\\}", file("${path.module}/vm.tf"))[0], "prevent_destroy = true")
    error_message = "The data disk has prevent_destroy."
  }
  assert {
    condition = alltrue([
      strcontains(local.cloud_init, "mount_point=/var/lib/docker"),
      strcontains(local.cloud_init, "/dev/disk/azure/scsi1/lun0"),
      strcontains(local.cloud_init, "nofail"),
      strcontains(local.cloud_init, "UUID=$uuid"),
      strcontains(local.cloud_init, "RequiresMountsFor=/var/lib/docker"),
      strcontains(local.cloud_init, "$host_src $host_root none bind,nofail"),
      strcontains(local.cloud_init, "host_root=/opt/margince"),
      strcontains(local.cloud_init, "admin_user=\"azureadmin\""),
      !strcontains(local.cloud_init, "docker-ce"),
      !strcontains(local.cloud_init, "nginx"),
      !strcontains(local.cloud_init, "git clone"),
    ])
    error_message = "cloud-init only mounts the data disk at /var/lib/docker by UUID with nofail."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.custom_data == base64encode(local.cloud_init)
    error_message = "The VM boots with the cloud-init document."
  }
}

run "backup_and_alarms" {
  command = plan
  assert {
    condition     = azurerm_backup_policy_vm.daily.backup[0].frequency == "Daily" && azurerm_backup_policy_vm.daily.retention_daily[0].count == 7
    error_message = "Daily backup of the VM with 7-day retention."
  }
  assert {
    condition     = azurerm_monitor_metric_alert.cpu_high.criteria[0].threshold == 90 && azurerm_monitor_metric_alert.cpu_high.window_size == "PT15M"
    error_message = "CPU alert: over 90% for 15 minutes."
  }
  assert {
    condition     = azurerm_monitor_metric_alert.vm_unavailable.criteria[0].metric_name == "VmAvailabilityMetric" && azurerm_monitor_metric_alert.vm_unavailable.window_size == "PT5M"
    error_message = "Availability alert: unavailable for 5 minutes."
  }
}

run "outputs" {
  command = apply
  assert {
    condition     = output.host_env == "HOST_SSH=azureadmin@198.51.100.7\nHOST_DOMAIN=crm.example.com\n"
    error_message = "host_env holds HOST_SSH and HOST_DOMAIN."
  }
  assert {
    condition     = output.dns_record == "crm.example.com A 198.51.100.7" && output.public_ip == "198.51.100.7"
    error_message = "dns_record points domain at the public IP."
  }
  assert {
    condition     = strcontains(output.ssh_known_hosts_hint, "ssh-keyscan -t ed25519 198.51.100.7") && strcontains(output.ssh_known_hosts_hint, "HOST_KNOWN_HOSTS")
    error_message = "ssh_known_hosts_hint reads the host key of the public IP."
  }
  assert {
    condition     = output.secret_names == tolist(["MARGINCE_GRAPH_CLIENT_ID", "MARGINCE_GRAPH_CLIENT_SECRET", "MARGINCE_GRAPH_TENANT", "MARGINCE_LICENSE", "MARGINCE_MICROSOFT_SIGNIN_TENANT"])
    error_message = "secret_names lists the Entra values and the license."
  }
  assert {
    condition     = contains(keys(azurerm_key_vault_secret.this), "margince-license") && contains(keys(azurerm_key_vault_secret.this), "margince-entra-client-secret")
    error_message = "Key Vault holds the license and the Entra client secret."
  }
}

run "no_license" {
  command = plan
  variables {
    license_token = ""
  }
  assert {
    condition     = !contains(keys(local.kv_secrets), "margince-license") && !contains(output.secret_names, "MARGINCE_LICENSE")
    error_message = "Without a license no license secret is stored or listed."
  }
}

run "empty_ssh_allowed_cidrs_refused" {
  command = plan
  variables {
    ssh_allowed_cidrs = []
  }
  expect_failures = [var.ssh_allowed_cidrs]
}

run "ssh_from_anywhere_refused" {
  command = plan
  variables {
    ssh_allowed_cidrs = ["203.0.113.10/32", "0.0.0.0/0"]
  }
  expect_failures = [var.ssh_allowed_cidrs]
}

run "ssh_from_anywhere_ipv6_refused" {
  command = plan
  variables {
    ssh_allowed_cidrs = ["::/0"]
  }
  expect_failures = [var.ssh_allowed_cidrs]
}

run "entra_group_required" {
  command = plan
  variables {
    entra_access_group_object_id = ""
  }
  expect_failures = [var.entra_access_group_object_id]
}
