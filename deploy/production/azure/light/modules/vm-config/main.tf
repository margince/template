# Renders everything the Margince VM needs at first boot: the cloud-init
# document with the environment files, nginx config, systemd units and helper
# scripts. Used by the light stack (vm.tf) with real Azure values, and by the
# local test harness (test/local/light) with stand-ins, so both boot exactly
# the same files.

locals {
  api_port      = 8080
  mcp_apps_port = 8081

  nginx_conf = templatefile("${path.module}/templates/nginx.conf.tftpl", {
    api_port          = local.api_port
    mcp_apps_port     = local.mcp_apps_port
    auth_rate         = var.auth_rate_limit_per_minute
    break_glass_cidrs = var.break_glass_cidrs
    tls_dir           = "/etc/margince/tls"
  })

  # Plain (non-secret) environment of margince-api and margince-worker.
  app_env = merge(
    {
      MARGINCE_CONFIG          = "/app/config/margince.yaml"
      MARGINCE_REDIS           = "127.0.0.1:6379" # Redis on loopback, no TLS
      MARGINCE_PUBLIC_BASE_URL = var.public_base_url
      MARGINCE_LOG_FORMAT      = "json"
      MARGINCE_BLOBSTORE_PATH  = "/var/lib/margince/blobstore"
      MARGINCE_GRAPH_CLIENT_ID = var.entra_client_id
      MARGINCE_GRAPH_TENANT    = var.entra_tenant_id
      # Microsoft sign-in, pinned to the customer's directory.
      MARGINCE_MICROSOFT_SIGNIN_TENANT = var.entra_tenant_id
      # nginx on the same host is the only peer cmd/api sees. This tells the
      # api to trust nginx's X-Real-IP for its per-client limits; Margince
      # versions without the setting ignore it, and nginx's own per-client
      # limits on the sign-in paths are what applies.
      MARGINCE_TRUSTED_PROXIES = "127.0.0.1/32"
      # MCP App views come from nginx's loopback listener, not a hairpin
      # through the public IP.
      MARGINCE_MCP_APPS_BASE_URL = "http://127.0.0.1:${local.mcp_apps_port}"
    },
    # Only "dev" and "test" give the non-production licensing posture.
    var.environment_posture == "development" ? { MARGINCE_ENV = "dev" } : {},
  )

  # Environment variable => Key Vault secret, read by margince-fetch-secrets.
  # The two DSNs and the Graph push values are composed on the VM from the
  # role passwords and the push token.
  secret_env = merge(
    {
      MARGINCE_KEYVAULT_ROOT_KEY   = "margince-keyvault-root-key"
      MARGINCE_WEBHOOK_KEY         = "margince-webhook-key"
      MARGINCE_CONNECTOR_STATE_KEY = "margince-connector-state-key"
      MARGINCE_GRAPH_CLIENT_SECRET = "margince-entra-client-secret"
      MARGINCE_METRICS_TOKEN       = "margince-metrics-token"
    },
    var.include_bootstrap_admin ? { MARGINCE_ADMIN_PASSWORD = "margince-admin-password" } : {},
    var.license_present ? { MARGINCE_LICENSE = "margince-license" } : {},
  )

  # Sourced by the helper scripts. Values are validated in variables.tf to
  # contain no quotes.
  deploy_env = <<-EOT
    KEY_VAULT_NAME='${var.key_vault_name}'
    PG_HOST='${var.pg_host}'
    PUBLIC_HOST='${var.public_host}'
    PUBLIC_BASE_URL='${var.public_base_url}'
    AZURE_FQDN='${var.azure_fqdn}'
    GIT_URL='${var.git_url}'
    GIT_REF='${var.git_ref}'
    ACME_EMAIL='${var.acme_email}'
    WORKSPACE_NAME='${var.workspace_name}'
    WORKSPACE_BASE_CURRENCY='${var.workspace_base_currency}'
    WORKSPACE_BASE_LANGUAGE='${var.workspace_base_language}'
    WORKSPACE_TIMEZONE='${var.workspace_timezone}'
    ADMIN_EMAIL='${var.admin_email}'
    ADMIN_DISPLAY_NAME='${var.admin_display_name}'
  EOT

  vm_files = {
    "/etc/margince/deploy.env"                    = { perm = "0644", content = local.deploy_env }
    "/etc/margince/app.env"                       = { perm = "0644", content = join("", [for k, v in local.app_env : "${k}=${v}\n"]) }
    "/etc/margince/secret-map"                    = { perm = "0644", content = join("", [for k, v in local.secret_env : "${k} ${v}\n"]) }
    "/etc/margince/nginx.conf"                    = { perm = "0644", content = local.nginx_conf }
    "/etc/systemd/system/margince-api.service"    = { perm = "0644", content = file("${path.module}/templates/systemd/margince-api.service") }
    "/etc/systemd/system/margince-worker.service" = { perm = "0644", content = file("${path.module}/templates/systemd/margince-worker.service") }
    "/usr/local/sbin/margince-setup"              = { perm = "0755", content = file("${path.module}/templates/scripts/margince-setup.sh") }
    "/usr/local/sbin/margince-build"              = { perm = "0755", content = file("${path.module}/templates/scripts/margince-build.sh") }
    "/usr/local/sbin/margince-fetch-secrets"      = { perm = "0755", content = file("${path.module}/templates/scripts/margince-fetch-secrets.sh") }
    "/usr/local/sbin/margince-bootstrap-db"       = { perm = "0755", content = file("${path.module}/templates/scripts/margince-bootstrap-db.sh") }
    "/usr/local/sbin/margince-enable-tls"         = { perm = "0755", content = file("${path.module}/templates/scripts/margince-enable-tls.sh") }
  }

  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    files = { for p, f in local.vm_files : p => { perm = f.perm, b64 = base64gzip(f.content) } }
  })
}

