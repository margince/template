# Redis 7.2 as a single-replica container app inside the environment.
# Margince needs Redis 7.0-7.2; Azure Cache for Redis Basic/Standard only
# offers Redis 6, and Azure Managed Redis runs 7.4. The image is the one
# Margince develops against, pinned by digest.
#
# Redis is the outbox relay: an evicted key is a lost event. noeviction plus
# maxmemory makes memory pressure fail loudly (OOM errors to the client)
# instead of dropping events or letting the container be OOM-killed.
#
# Persistence: AOF (fsync every second) and the default RDB snapshots on the
# redis Azure Files share mounted at /data. The share has soft delete and the
# daily Azure Backup (storage.tf).
#
# Limits of one replica:
#   - Not zone-redundant: a zone or node failure restarts Redis elsewhere and
#     it reloads the AOF from the share.
#   - A new revision would briefly run next to the old one on the same /data
#     and can corrupt the AOF. lifecycle below ignores template changes, so a
#     plain apply never creates one. Change Redis with
#     `terraform apply -replace=azurerm_container_app.redis`: the replacement
#     destroys the old app before it creates the new one.

resource "random_password" "redis" {
  length  = 40
  special = false
}

resource "azurerm_storage_share" "redis" {
  name               = "${var.name_prefix}-redis"
  storage_account_id = azurerm_storage_account.this.id
  quota              = 16 # GiB; billed on use, not quota
}

resource "azurerm_container_app_environment_storage" "redis" {
  name                         = "redis"
  container_app_environment_id = azurerm_container_app_environment.this.id
  account_name                 = azurerm_storage_account.this.name
  share_name                   = azurerm_storage_share.redis.name
  access_key                   = azurerm_storage_account.this.primary_access_key
  access_mode                  = "ReadWrite"
}

# Reads only the Redis password secret. No AcrPull: the image comes from
# Docker Hub through the NAT gateway.
resource "azurerm_user_assigned_identity" "redis" {
  name                = "${var.name_prefix}-redis"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-redis", Component = "security" })
}

resource "azurerm_role_assignment" "redis_secret" {
  scope                = azurerm_key_vault_secret.redis_password.resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.redis.principal_id
}

resource "azurerm_container_app" "redis" {
  name                         = "${var.name_prefix}-redis"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.redis.id]
  }

  secret {
    name                = "redis-password"
    key_vault_secret_id = azurerm_key_vault_secret.redis_password.versionless_id
    identity            = azurerm_user_assigned_identity.redis.id
  }

  # Internal TCP ingress: api and worker reach it as <app name>:6379 inside
  # the environment. Nothing outside the environment can connect.
  ingress {
    external_enabled = false
    transport        = "tcp"
    target_port      = 6379
    exposed_port     = 6379
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    volume {
      name         = "data"
      storage_name = azurerm_container_app_environment_storage.redis.name
      storage_type = "AzureFile"
    }

    container {
      name = "redis"
      # The image core's docker-compose.dev.yml uses, pinned by digest.
      image  = "docker.io/library/redis:7.2@sha256:6461ca4ac0c5c9d81d53685c3bf76aa81f464a9de6cf3a97b80a1da8d1bb1de4"
      cpu    = 0.5
      memory = "1Gi"
      # sh -c so $REDIS_PASSWORD expands. This skips the image entrypoint,
      # whose chown to the redis user fails on an SMB mount, so Redis runs
      # as the container's root user.
      command = ["/bin/sh", "-c"]
      args = [join(" ", [
        "exec redis-server --requirepass \"$REDIS_PASSWORD\"",
        "--appendonly yes --appendfsync everysec --dir /data",
        # Well below the container's 1Gi, so writes fail before an OOM kill.
        "--maxmemory 768mb --maxmemory-policy noeviction --protected-mode yes",
      ])]

      env {
        name        = "REDIS_PASSWORD"
        secret_name = "redis-password"
      }

      volume_mounts {
        name = "data"
        path = "/data"
      }

      # Loading a large AOF can take a while after a restart.
      startup_probe {
        transport               = "TCP"
        port                    = 6379
        interval_seconds        = 10
        failure_count_threshold = 30
      }

      readiness_probe {
        transport = "TCP"
        port      = 6379
      }

      liveness_probe {
        transport = "TCP"
        port      = 6379
      }
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-redis", Component = "cache" })

  depends_on = [
    time_sleep.rbac_propagation,
    azurerm_private_endpoint.key_vault,
    azurerm_private_endpoint.storage,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
    azurerm_private_dns_zone_virtual_network_link.storage_file,
  ]

  lifecycle {
    # Image, resources and command live in template. Changing them in place
    # starts a second Redis on the same /data; use -replace instead (above).
    ignore_changes = [template]
  }
}
