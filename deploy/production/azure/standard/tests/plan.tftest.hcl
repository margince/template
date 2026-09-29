# Offline plan checks with mocked providers: no Azure or Entra access needed.
#   terraform init -backend=false && terraform test
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000001"
      object_id = "00000000-0000-0000-0000-000000000002"
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
}
mock_provider "random" {}
mock_provider "time" {}

variables {
  image_tag                    = "2026.09.28"
  public_base_url              = "https://crm.example.com"
  admin_bootstrap_password     = "change-me-before-first-boot"
  license_token                = "test-licence"
  entra_access_group_object_id = "00000000-0000-0000-0000-0000000000aa"
  jumpbox_ssh_public_key       = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC/vUmkEV7lfFP7t36rOoMbvwoNzx4r0gfQKltPmyKTIC6WILJaitH79JH2yJXHb8ePibRalweus+EV/EPKn0oUrOzjVsjVzMef9Rz5CoAovRnDe6z2+y84XnjlIeN5b58NkeBaliOlFv36enIfMluv/sOMHTjfBwbCooF+ChwYnz9p20V5y0DFe/axStpcKcmHW7RfRuijO+vxC+te9mhCbLdN1sJm6qC9pSeADHSDH/swyDK6l1526/+NJqHfryRbhuQ8uPDL7pT14Z02AFnvIMvYhvSomi4Kag9aFQLFmm2Jd1Yz6lERFj4i6+51WvD/ZPmC7OER6N09qlUdXo3qx8Amf472GAQl9VhVHtolycBNtKehQomHLNuBffSIiarnOH5hYwLQEBD3ixah4xbXlmDAb9p+Ub31ppEv9ZLA2YebcRPzUfy/bvBLxysWAJTSwrnTvP0/bJW4Egqa37prx8MQRQkB/yRiET3I3DHFlLDsSnKQnEYSEBmvvLvxE6s= test"
  break_glass_cidrs            = ["203.0.113.10/32"]
}

run "first_apply_without_apps" {
  command = plan
  assert {
    condition     = azurerm_key_vault.this.public_network_access_enabled && azurerm_key_vault.this.network_acls[0].default_action == "Deny" && azurerm_storage_account.this.public_network_access_enabled && azurerm_storage_account.this.network_rules[0].default_action == "Deny"
    error_message = "Key Vault and Storage keep the public endpoint behind a default-deny firewall, so trusted-service CMK access keeps working."
  }
  assert {
    condition     = anytrue([for r in azurerm_network_security_group.postgres.security_rule : r.name == "AllowPostgresSubnetInternal"])
    error_message = "The Postgres NSG admits traffic inside its own subnet for HA replication."
  }
  assert {
    condition     = length(azurerm_container_app.api) == 0 && length(azurerm_container_app.worker) == 0
    error_message = "deploy_apps defaults to false: no apps on the first apply."
  }
  assert {
    condition     = length(azurerm_private_endpoint.storage) == 2
    error_message = "Storage needs one private endpoint per sub-resource."
  }
  assert {
    condition     = startswith(azurerm_postgresql_flexible_server.this.sku_name, "B_") && contains(keys(azurerm_monitor_metric_alert.this), "postgres-cpu-credits-low")
    error_message = "The Burstable default gets a CPU-credit alert."
  }
  assert {
    condition     = azurerm_postgresql_flexible_server.this.auto_grow_enabled && azurerm_postgresql_flexible_server.this.authentication[0].active_directory_auth_enabled
    error_message = "Postgres has auto-grow and Entra authentication on."
  }
  assert {
    condition     = length(azurerm_management_lock.this) == 5
    error_message = "Postgres, storage, Key Vault, ACR and the Recovery Services vault are locked."
  }
  assert {
    condition = (
      azurerm_container_app.redis.ingress[0].transport == "tcp" &&
      !azurerm_container_app.redis.ingress[0].external_enabled &&
      endswith(azurerm_container_app.redis.template[0].container[0].image, "@sha256:6461ca4ac0c5c9d81d53685c3bf76aa81f464a9de6cf3a97b80a1da8d1bb1de4") &&
      azurerm_container_app.redis.template[0].max_replicas == 1
    )
    error_message = "Redis runs as one internal TCP container app on the pinned 7.2 image."
  }
  assert {
    condition     = length([for r in keys(azurerm_monitor_metric_alert.this) : r if startswith(r, "redis-")]) == 1 && contains([for e in local.common_env : e.value if e.name == "MARGINCE_REDIS"], "margince-redis:6379")
    error_message = "The apps point at the redis app, which has a restart alert."
  }
  assert {
    condition     = length(azurerm_network_watcher_flow_log.vnet) == 1 && azurerm_network_watcher_flow_log.vnet[0].retention_policy[0].days == 90
    error_message = "VNet flow logs are on with 90-day retention."
  }
}

run "full_apply_with_apps_and_domain" {
  command = plan
  variables {
    deploy_apps        = true
    bind_custom_domain = true
  }
  assert {
    condition     = length(azurerm_container_app.api) == 1 && length(azurerm_container_app_custom_domain.public) == 1
    error_message = "Apps and the custom domain are created when enabled."
  }
  assert {
    condition     = strcontains(local.edge_nginx_conf, "return 301 https://crm.example.com$request_uri")
    error_message = "The default hostname redirects once the domain is bound."
  }
  assert {
    condition     = !contains(keys(local.worker_secrets), "owner-dsn") && contains(keys(local.api_secrets), "owner-dsn")
    error_message = "Only the api (migrations) gets the owner DSN."
  }
  assert {
    condition     = azurerm_container_app.api[0].template[0].http_scale_rule[0].concurrent_requests == "50" && azurerm_container_app.api[0].template[0].min_replicas == 3
    error_message = "The api app scales on HTTP concurrency and keeps three replicas."
  }
  assert {
    condition     = contains(keys(azurerm_monitor_metric_alert.this), "api-5xx")
    error_message = "The api app gets a 5xx alert once deployed."
  }
}

run "general_purpose_with_ha_and_no_locks" {
  command = plan
  variables {
    db_sku_name           = "GP_Standard_D2ds_v5"
    db_zone_redundant_ha  = true
    enable_resource_locks = false
  }
  assert {
    condition     = length(azurerm_management_lock.this) == 0 && !contains(keys(azurerm_monitor_metric_alert.this), "postgres-cpu-credits-low")
    error_message = "Locks can be turned off, and the CPU-credit alert is Burstable-only."
  }
}

run "ha_on_burstable_is_refused" {
  command = plan
  variables {
    db_zone_redundant_ha = true
  }
  expect_failures = [azurerm_postgresql_flexible_server.this]
}

run "production_without_licence_is_refused" {
  command = plan
  variables {
    license_token = ""
  }
  expect_failures = [azurerm_key_vault_secret.license]
}

run "development_posture_boots_unlicensed" {
  command = plan
  variables {
    license_token       = ""
    environment_posture = "development"
    deploy_apps         = true
  }
  assert {
    condition     = contains([for e in local.common_env : e.name], "MARGINCE_ENV")
    error_message = "Development posture sets MARGINCE_ENV."
  }
}
