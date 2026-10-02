resource "azurerm_container_app_environment" "this" {
  name                = "${var.name_prefix}-env"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  infrastructure_subnet_id   = azurerm_subnet.containerapps.id

  # Internal: the environment's load balancer has a private IP in the
  # containerapps subnet and no public endpoint. The Application Gateway
  # (appgw.tf) is the only public entry; it reaches the api app's ingress
  # over the VNet, and appgw.tf's private DNS zone resolves the
  # environment's default domain to that IP. worker has no ingress.
  internal_load_balancer_enabled = true

  # Zone redundancy needs the environment's subnet at creation time
  # (network.tf's azurerm_subnet.containerapps, /23).
  zone_redundancy_enabled = true

  # Named explicitly: Azure generates one for workload profiles environments,
  # and the argument forces replacement, so leaving it unset risks a plan that
  # replaces the environment and every app.
  infrastructure_resource_group_name = "${local.global_prefix}-env-infra"

  # A workload profiles environment running only the serverless Consumption
  # profile: same per-second billing as a Consumption-only environment, but
  # the Consumption-only type (legacy) does not support egress through NAT
  # Gateway, so network.tf's NAT would not give api/worker a fixed outbound
  # IP (learn.microsoft.com/azure/container-apps/networking). That fixed IP
  # is what the Dataverse IP firewall allowlists (nat_egress_ip output).
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-env", Component = "compute" })
}

# Mounted read-only at /app/config on api and worker. The operator uploads
# margince.yaml to this share once by hand (README.md step 4); Terraform does
# not write it.
resource "azurerm_container_app_environment_storage" "config" {
  name                         = "config"
  container_app_environment_id = azurerm_container_app_environment.this.id
  account_name                 = azurerm_storage_account.this.name
  share_name                   = azurerm_storage_share.config.name
  access_key                   = azurerm_storage_account.this.primary_access_key
  access_mode                  = "ReadOnly"
}

# Read-write attachment store for api and worker (storage.tf's attachments
# share), exposed to Margince as MARGINCE_BLOBSTORE_PATH.
resource "azurerm_container_app_environment_storage" "attachments" {
  name                         = "attachments"
  container_app_environment_id = azurerm_container_app_environment.this.id
  account_name                 = azurerm_storage_account.this.name
  share_name                   = azurerm_storage_share.attachments.name
  access_key                   = azurerm_storage_account.this.primary_access_key
  access_mode                  = "ReadWrite"
}

locals {
  # ---- Secrets, per role --------------------------------------------------
  # Each role gets only the secrets its process reads; identity.tf grants the
  # role's identity Key Vault Secrets User on exactly these secrets.
  secret_catalog = {
    owner-dsn           = { id = azurerm_key_vault_secret.owner_dsn, env = "MARGINCE_OWNER_DSN" } # api entrypoint: migrations
    app-dsn             = { id = azurerm_key_vault_secret.app_dsn, env = "MARGINCE_DSN" }
    redis-password      = { id = azurerm_key_vault_secret.redis_password, env = "MARGINCE_REDIS_PASSWORD" }
    keyvault-root-key   = { id = azurerm_key_vault_secret.keyvault_root_key, env = "MARGINCE_KEYVAULT_ROOT_KEY" }
    webhook-key         = { id = azurerm_key_vault_secret.webhook_key, env = "MARGINCE_WEBHOOK_KEY" }
    connector-state-key = { id = azurerm_key_vault_secret.connector_state_key, env = "MARGINCE_CONNECTOR_STATE_KEY" }
    admin-password      = { id = azurerm_key_vault_secret.admin_password, env = "MARGINCE_ADMIN_PASSWORD" } # api entrypoint: first boot only
    license             = { id = azurerm_key_vault_secret.license, env = "MARGINCE_LICENSE" }
    graph-push-token    = { id = azurerm_key_vault_secret.graph_push_token, env = "MARGINCE_GRAPH_PUSH_TOKEN" }
    graph-notify-url    = { id = azurerm_key_vault_secret.graph_notification_url, env = "MARGINCE_GRAPH_NOTIFICATION_URL" }
    metrics-token       = { id = azurerm_key_vault_secret.metrics_token, env = "MARGINCE_METRICS_TOKEN" }
  }

  api_secret_names = concat(
    ["owner-dsn", "app-dsn", "redis-password", "keyvault-root-key", "webhook-key",
    "connector-state-key", "license", "graph-push-token", "metrics-token"],
    var.include_bootstrap_admin ? ["admin-password"] : [],
  )
  worker_secret_names = ["app-dsn", "redis-password", "keyvault-root-key", "webhook-key", "graph-notify-url"]

  api_secrets    = { for n in local.api_secret_names : n => local.secret_catalog[n] }
  worker_secrets = { for n in local.worker_secret_names : n => local.secret_catalog[n] }

  # ---- Plain environment ---------------------------------------------------
  common_env = [
    { name = "MARGINCE_CONFIG", value = "/app/config/margince.yaml" },
    # The redis app's internal TCP ingress (redis.tf). No TLS: the traffic
    # never leaves the environment, and the password is still required.
    { name = "MARGINCE_REDIS", value = "${azurerm_container_app.redis.name}:6379" },
    { name = "MARGINCE_PUBLIC_BASE_URL", value = var.public_base_url },
    { name = "MARGINCE_LOG_FORMAT", value = "json" },
    # Attachments: Margince's filesystem store on the attachments share,
    # because its object-store client speaks S3 only (storage.tf).
    { name = "MARGINCE_BLOBSTORE_PATH", value = "/app/blobstore" },
  ]

  api_env = concat(local.common_env, [
    # The edge in the same replica serves the MCP App views; no hairpin
    # through the public internet.
    { name = "MARGINCE_MCP_APPS_BASE_URL", value = "http://127.0.0.1:${local.edge_port}" },
    # The edge in the same replica is the api's only proxy: it resolves the
    # client from the gateway and the environment (real_ip) and passes it in
    # X-Forwarded-For. Trusting 127.0.0.1 makes core key every per-IP limit
    # (sign-in, password reset, OIDC, /oauth/token, MCP, public pages) on
    # that client; unset, every client shares the edge's one bucket
    # (core docs/reference/configuration.md, MARGINCE_TRUSTED_PROXIES).
    { name = "MARGINCE_TRUSTED_PROXIES", value = "127.0.0.1/32" },
  ])

  worker_env = concat(local.common_env, [
    { name = "MARGINCE_OBSERVE_ADDR", value = "0.0.0.0:${local.worker_observe_port}" },
  ])

  # ---- Edge ------------------------------------------------------------------
  # The edge container's complete nginx config (templates/edge-nginx.conf.tftpl),
  # passed as a plain environment variable and written to /tmp at start.
  edge_port           = 8081
  api_port            = 8080 # cmd/api listens on :8080 (its entrypoint takes no --addr)
  worker_observe_port = 9101
  public_host         = trimprefix(var.public_base_url, "https://")
  edge_nginx_conf = templatefile("${path.module}/templates/edge-nginx.conf.tftpl", {
    edge_port  = local.edge_port
    api_port   = local.api_port
    envoy_cidr = azurerm_subnet.containerapps.address_prefixes[0]
    appgw_cidr = azurerm_subnet.appgw.address_prefixes[0]
    # Requests per minute per client address on the sign-in paths (burst of
    # the same size). Staff behind one office NAT share one address.
    auth_rate   = 30
    public_host = local.public_host
  })
}

# Role assignments take up to a minute to reach Key Vault; a revision
# created sooner fails its secret fetch.
resource "time_sleep" "rbac_propagation" {
  depends_on = [
    azurerm_role_assignment.api_secret,
    azurerm_role_assignment.worker_secret,
    azurerm_role_assignment.redis_secret,
  ]
  create_duration = "60s"
}

resource "azurerm_container_app" "api" {
  count                        = var.deploy_apps ? 1 : 0
  name                         = "${var.name_prefix}-api"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type = "UserAssigned"
    identity_ids = [
      azurerm_user_assigned_identity.api.id,
      azurerm_user_assigned_identity.dataverse.id,
    ]
  }

  dynamic "secret" {
    for_each = local.api_secrets
    content {
      name = secret.key
      # Versioned id: a new secret version changes the app itself, so its
      # new revision starts with the new value. A versionless id is re-read
      # only on Container Apps' own refresh cycle.
      key_vault_secret_id = secret.value.id.id
      identity            = azurerm_user_assigned_identity.api.id
    }
  }

  # The Application Gateway's backend (appgw.tf). external_enabled makes the
  # ingress reachable from the VNet; the environment is internal, so nothing
  # outside the VNet reaches it. It targets the edge container, never
  # cmd/api directly: edge serves the SPA, applies the rate limits, and
  # forwards api paths to cmd/api on localhost. The gateway
  # connects over HTTPS; HTTP is redirected to HTTPS.
  ingress {
    external_enabled           = true
    target_port                = local.edge_port
    allow_insecure_connections = false
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.api_min_replicas
    max_replicas = var.api_max_replicas

    volume {
      name         = "config"
      storage_name = azurerm_container_app_environment_storage.config.name
      storage_type = "AzureFile"
    }

    volume {
      name         = "attachments"
      storage_name = azurerm_container_app_environment_storage.attachments.name
      storage_type = "AzureFile"
    }

    container {
      name   = "api"
      image  = local.images.api
      cpu    = 0.5
      memory = "1Gi"

      dynamic "env" {
        for_each = local.api_env
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      dynamic "env" {
        for_each = local.api_secrets
        content {
          name        = env.value.env
          secret_name = env.key
        }
      }

      volume_mounts {
        name = "config"
        path = "/app/config"
      }

      volume_mounts {
        name = "attachments"
        path = "/app/blobstore"
      }

      # Migrations run in the entrypoint before cmd/api listens: allow up to
      # five minutes before liveness takes over.
      startup_probe {
        transport               = "HTTP"
        port                    = local.api_port
        path                    = "/healthz"
        interval_seconds        = 10
        failure_count_threshold = 30
      }

      liveness_probe {
        transport = "HTTP"
        port      = local.api_port
        path      = "/healthz"
      }
    }

    # edge: nginx from the web image (it carries the built SPA), sharing this
    # replica's network with cmd/api (templates/edge-nginx.conf.tftpl).
    # api + edge add up to 0.75 vCPU / 1.5Gi, a valid Consumption combination
    # (learn.microsoft.com/azure/container-apps/containers#allocations).
    container {
      name    = "edge"
      image   = local.images.web
      cpu     = 0.25
      memory  = "0.5Gi"
      command = ["/bin/sh", "-c"]
      args    = ["printf '%s' \"$NGINX_CONF\" > /tmp/nginx.conf && exec nginx -c /tmp/nginx.conf -g 'daemon off;'"]

      env {
        name  = "NGINX_CONF"
        value = local.edge_nginx_conf
      }

      # Ready when nginx answers and cmd/api's process does (/healthz), not
      # when every dependency is up (/readyz): Redis is one replica, and a
      # dependency check here would mark all api replicas unready together on
      # a Redis restart, leaving ingress nothing to route to. Dependency
      # health is covered by the alerts (alarms.tf).
      readiness_probe {
        transport = "HTTP"
        port      = local.edge_port
        path      = "/healthz"
      }

      liveness_probe {
        transport = "HTTP"
        port      = local.edge_port
        path      = "/livez"
      }
    }

    custom_scale_rule {
      name             = "cpu-scaling"
      custom_rule_type = "cpu"
      metadata = {
        type  = "Utilization"
        value = "70"
      }
    }

    # Scales on load before CPU saturates; the replica count follows the
    # busier of the two rules.
    http_scale_rule {
      name                = "http-scaling"
      concurrent_requests = "50"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-api", Component = "compute-api" })

  # Everything a revision needs before it can read its secrets over the
  # private endpoints.
  depends_on = [
    time_sleep.rbac_propagation,
    azurerm_private_endpoint.key_vault,
    azurerm_private_endpoint.storage,
    azurerm_container_app.redis,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
    azurerm_private_dns_zone_virtual_network_link.storage_file,
    azurerm_postgresql_flexible_server_configuration.azure_extensions,
    # The database exists and margince.yaml is in place (setup.tf).
    terraform_data.setup,
  ]
}

resource "azurerm_container_app" "worker" {
  count                        = var.deploy_apps ? 1 : 0
  name                         = "${var.name_prefix}-worker"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type = "UserAssigned"
    identity_ids = [
      azurerm_user_assigned_identity.worker.id,
      azurerm_user_assigned_identity.dataverse.id,
    ]
  }

  dynamic "secret" {
    for_each = local.worker_secrets
    content {
      name = secret.key
      # Versioned id: a new secret version changes the app itself, so its
      # new revision starts with the new value. A versionless id is re-read
      # only on Container Apps' own refresh cycle.
      key_vault_secret_id = secret.value.id.id
      identity            = azurerm_user_assigned_identity.worker.id
    }
  }

  # No ingress: worker only drains queues and runs periodic jobs.

  template {
    # At least one replica: worker owns the periodic jobs (capture sync, AI
    # passes), and a cpu rule cannot start it from zero.
    min_replicas = 1
    max_replicas = 3

    volume {
      name         = "config"
      storage_name = azurerm_container_app_environment_storage.config.name
      storage_type = "AzureFile"
    }

    volume {
      name         = "attachments"
      storage_name = azurerm_container_app_environment_storage.attachments.name
      storage_type = "AzureFile"
    }

    container {
      name   = "worker"
      image  = local.images.worker
      cpu    = 0.5
      memory = "1Gi"

      dynamic "env" {
        for_each = local.worker_env
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      dynamic "env" {
        for_each = local.worker_secrets
        content {
          name        = env.value.env
          secret_name = env.key
        }
      }

      volume_mounts {
        name = "config"
        path = "/app/config"
      }

      volume_mounts {
        name = "attachments"
        path = "/app/blobstore"
      }

      # cmd/worker serves /healthz and /readyz on its observe address.
      startup_probe {
        transport               = "HTTP"
        port                    = local.worker_observe_port
        path                    = "/healthz"
        interval_seconds        = 10
        failure_count_threshold = 30
      }

      readiness_probe {
        transport = "HTTP"
        port      = local.worker_observe_port
        path      = "/readyz"
      }

      liveness_probe {
        transport = "HTTP"
        port      = local.worker_observe_port
        path      = "/healthz"
      }
    }

    custom_scale_rule {
      name             = "cpu-scaling"
      custom_rule_type = "cpu"
      metadata = {
        type  = "Utilization"
        value = "70"
      }
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-worker", Component = "compute-worker" })

  # Everything a revision needs before it can read its secrets over the
  # private endpoints.
  depends_on = [
    time_sleep.rbac_propagation,
    azurerm_private_endpoint.key_vault,
    azurerm_private_endpoint.storage,
    azurerm_container_app.redis,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
    azurerm_private_dns_zone_virtual_network_link.storage_file,
    azurerm_postgresql_flexible_server_configuration.azure_extensions,
    # The database exists and margince.yaml is in place (setup.tf).
    terraform_data.setup,
  ]
}
