# ---- First-time setup, part of every apply ------------------------------------
# One Container Apps job, run by Terraform before the apps (terraform_data.setup
# below), does what an operator used to do from the jumpbox:
#
#   prepare   init container, core's api image: writes margince.yaml (the
#             instance's deploy/<env>/config/margince.yaml, the file the light
#             stacks use) onto the config share, and the image's CA bundle,
#             which holds the roots of Flexible Server's certificate, onto a
#             scratch volume for psql
#   database  the template's Postgres image: runs core's db-bootstrap.sql as
#             pgadmin through scripts/bootstrap-db.sh (the same file as the AWS
#             stack's), after prepare (core/docs/deployment.md, "Order of
#             operations": bootstrap the database before the api)
#
# The SQL is idempotent, so the job runs again whenever its inputs change (a new
# margince.yaml, a new core SQL, a new release image) and changes nothing else.
# scripts/run-setup.sh starts it with the Azure CLI and fails the apply unless
# the execution succeeds. The job runs in the first apply (deploy_apps = false):
# the environment exists then, the apps do not.

locals {
  # The Postgres image the template's host adapter pins
  # (scripts/deploy/host/compose.yaml), for its psql.
  setup_postgres_image = "pgvector/pgvector:pg16@sha256:1d533553fefe4f12e5d80c7b80622ba0c382abb5758856f52983d8789179f0fb"
  margince_config_path = coalesce(var.margince_config_path, "${path.module}/../../config/margince.yaml")
  bootstrap_sql_path   = coalesce(var.bootstrap_sql_path, "${path.module}/../../../../core/scripts/deploy/db-bootstrap.sql")

  setup_prepare_script = join("\n", [
    "set -eu",
    "printf '%s' \"$MARGINCE_CONFIG_B64\" | base64 -d > /config/margince.yaml.tmp",
    "mv /config/margince.yaml.tmp /config/margince.yaml",
    "cp /etc/ssl/certs/ca-certificates.crt /setup/ca.pem",
    "echo 'setup: margince.yaml is on the config share'",
  ])

  setup_database_script = join("\n", [
    "set -euo pipefail",
    "printf '%s' \"$BOOTSTRAP_SCRIPT_B64\" | base64 -d > /tmp/bootstrap-db.sh",
    "printf '%s' \"$BOOTSTRAP_SQL_B64\" | base64 -d > /tmp/db-bootstrap.sql",
    "exec bash /tmp/bootstrap-db.sh /tmp/db-bootstrap.sql",
  ])

  setup_env = {
    MARGINCE_CONFIG_B64     = filebase64(local.margince_config_path)
    BOOTSTRAP_SCRIPT_B64    = filebase64("${path.module}/scripts/bootstrap-db.sh")
    BOOTSTRAP_SQL_B64       = filebase64(local.bootstrap_sql_path)
    BOOTSTRAP_PG_HOST       = azurerm_postgresql_flexible_server.this.fqdn
    BOOTSTRAP_PG_ADMIN_USER = "pgadmin"
    BOOTSTRAP_PGSSLROOTCERT = "/setup/ca.pem"
  }

  # Container Apps secrets of the job, readable by the job only.
  setup_secrets = {
    "pg-admin-password" = { env = "BOOTSTRAP_PG_ADMIN_PASSWORD", value = random_password.postgres_admin.result }
    "owner-password"    = { env = "BOOTSTRAP_OWNER_PASSWORD", value = random_password.margince_owner.result }
    "app-password"      = { env = "BOOTSTRAP_APP_PASSWORD", value = random_password.margince_app.result }
  }
}

# The config share again, read-write, for the job only; the apps mount it
# read-only (containerapps.tf).
resource "azurerm_container_app_environment_storage" "config_setup" {
  name                         = "config-setup"
  container_app_environment_id = azurerm_container_app_environment.this.id
  account_name                 = azurerm_storage_account.this.name
  share_name                   = azurerm_storage_share.config.name
  access_key                   = azurerm_storage_account.this.primary_access_key
  access_mode                  = "ReadWrite"
}

resource "azurerm_container_app_job" "setup" {
  name                         = "${var.name_prefix}-setup"
  location                     = azurerm_resource_group.this.location
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  workload_profile_name        = "Consumption"
  replica_timeout_in_seconds   = 600
  replica_retry_limit          = 0
  tags                         = merge(local.common_tags, { Name = "${var.name_prefix}-setup", Component = "operations" })

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  dynamic "secret" {
    for_each = local.setup_secrets
    content {
      name  = secret.key
      value = secret.value.value
    }
  }

  template {
    volume {
      name         = "config"
      storage_name = azurerm_container_app_environment_storage.config_setup.name
      storage_type = "AzureFile"
    }

    volume {
      name         = "setup"
      storage_type = "EmptyDir"
    }

    init_container {
      name    = "prepare"
      image   = local.images.api
      cpu     = 0.25
      memory  = "0.5Gi"
      command = ["sh", "-c", local.setup_prepare_script]

      env {
        name  = "MARGINCE_CONFIG_B64"
        value = local.setup_env.MARGINCE_CONFIG_B64
      }

      volume_mounts {
        name = "config"
        path = "/config"
      }

      volume_mounts {
        name = "setup"
        path = "/setup"
      }
    }

    container {
      name    = "database"
      image   = local.setup_postgres_image
      cpu     = 0.25
      memory  = "0.5Gi"
      command = ["bash", "-c", local.setup_database_script]

      dynamic "env" {
        for_each = { for k, v in local.setup_env : k => v if k != "MARGINCE_CONFIG_B64" }
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.setup_secrets
        content {
          name        = env.value.env
          secret_name = env.key
        }
      }

      volume_mounts {
        name = "setup"
        path = "/setup"
      }
    }
  }

  depends_on = [
    azurerm_postgresql_flexible_server_configuration.azure_extensions,
    azurerm_private_dns_zone_virtual_network_link.postgres,
    azurerm_private_endpoint.storage,
    azurerm_private_dns_zone_virtual_network_link.storage_file,
  ]
}

# Runs the job once per change of its inputs, before the apps (their
# depends_on), and fails the apply if the execution fails.
resource "terraform_data" "setup" {
  triggers_replace = [
    sha256(jsonencode(local.setup_env)),
    local.images.api,
    local.setup_postgres_image,
    sha256(local.setup_prepare_script),
    sha256(local.setup_database_script),
  ]

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/run-setup.sh"
    environment = {
      RESOURCE_GROUP = azurerm_resource_group.this.name
      JOB            = azurerm_container_app_job.setup.name
    }
  }

  depends_on = [azurerm_container_app_job.setup]
}
