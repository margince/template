# Application Gateway WAF v2: the one public entry, the Azure counterpart of
# the AWS standard stack's ALB with its WAF web ACL.
#
#   Internet -> public IP -> Application Gateway (TLS, WAF policy)
#            -> HTTPS -> api app ingress (internal environment, private IP)
#            -> edge (nginx) -> cmd/api on localhost
#
# The Container Apps environment is internal (containerapps.tf), so the api
# app's ingress has no public endpoint; the gateway reaches it over the VNet.
# The private DNS zone below resolves the environment's default domain, which
# the api app's FQDN belongs to, to the environment's private IP.
#
# The gateway, its certificate grant and the diagnostic setting follow
# deploy_apps: the backend is the api app, and the certificate is imported
# into Key Vault after the first apply (README.md, step 5). The public IP, the
# identity and the WAF policy exist from the first apply, so DNS can point at
# the gateway's address before the gateway exists.

locals {
  appgw_enabled = var.deploy_apps

  # Spread across two zones, like the zone-redundant Container Apps
  # environment.
  appgw_zones = ["1", "2"]

  # The Key Vault certificate for public_base_url's host (README.md, step 5).
  public_certificate_name = "public-tls"

  # The key vault object the gateway serves as its TLS certificate. The
  # versionless secret ID makes the gateway pick up a renewed certificate
  # (it polls Key Vault every four hours).
  public_certificate_secret_id = "${azurerm_key_vault.this.vault_uri}secrets/${local.public_certificate_name}"

  # The same provider webhook paths as the AWS stack's WAF. Provider webhook
  # traffic (Google, Microsoft Graph, HubSpot) is HMAC-verified by the api
  # and arrives in bursts from shared provider IPs, so it is exempt from the
  # global per-IP rate limit. Prefix match: the Graph validation handshake
  # carries a query string.
  webhook_paths = ["/webhooks/gmail", "/webhooks/graph", "/webhooks/hubspot"]

  # The api's credential-accepting endpoints, the same list as the AWS
  # stack: password login, forgot/reset password, OAuth token and dynamic
  # client registration. Prefix match, so a trailing slash or a query string
  # is matched too.
  waf_auth_paths = ["/v1/auth/login", "/v1/auth/forgot-password", "/v1/auth/reset-password", "/oauth/token", "/oauth/register"]

  waf_block = var.waf_mode == "block"
  # Custom rules follow waf_mode explicitly: Log in count mode, Block in
  # block mode, the counterparts of the AWS rules' count {} and block {}.
  waf_custom_action = local.waf_block ? "Block" : "Log"
}

resource "azurerm_public_ip" "appgw" {
  name                = "${var.name_prefix}-appgw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.appgw_zones
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-appgw", Component = "edge" })
}

# Reads the public certificate from Key Vault. Key Vault treats Application
# Gateway with a user-assigned identity as a trusted service, and the gateway
# resolves the vault to its private endpoint (network.tf allows 443 from the
# gateway subnet).
resource "azurerm_user_assigned_identity" "appgw" {
  name                = "${var.name_prefix}-appgw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-appgw", Component = "security" })
}

# Key Vault Secrets User on the one certificate's secret, never on the vault.
# The scope must exist when the grant is created, hence deploy_apps.
resource "azurerm_role_assignment" "appgw_certificate" {
  count                = local.appgw_enabled ? 1 : 0
  scope                = "${azurerm_key_vault.this.id}/secrets/${local.public_certificate_name}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.appgw.principal_id
}

resource "time_sleep" "appgw_rbac_propagation" {
  count           = local.appgw_enabled ? 1 : 0
  depends_on      = [azurerm_role_assignment.appgw_certificate]
  create_duration = "60s"
}

# ---- Private DNS for the internal environment ------------------------------------
# The api app's FQDN is <app>.<default_domain>. An internal environment
# publishes no public DNS for it, so this zone, linked to the VNet, maps the
# whole default domain to the environment's private IP.

resource "azurerm_private_dns_zone" "environment" {
  name                = azurerm_container_app_environment.this.default_domain
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-env", Component = "network" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "environment" {
  name                  = "${var.name_prefix}-env"
  private_dns_zone_name = azurerm_private_dns_zone.environment.name
  resource_group_name   = azurerm_resource_group.this.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_private_dns_a_record" "environment" {
  for_each            = toset(["*", "@"])
  name                = each.key
  zone_name           = azurerm_private_dns_zone.environment.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 300
  records             = [azurerm_container_app_environment.this.static_ip_address]
}

# ---- WAF policy ----------------------------------------------------------------------
# Rollout: waf_mode = "count" (default) sets Detection mode and every custom
# rule to Log, so nothing is blocked and every match is written to
# AGWFirewallLogs. After about a week of real traffic, add exclusions or rule
# overrides for the false positives, then set waf_mode = "block" (Prevention,
# custom rules Block). README "WAF rollout" has the queries.
#
# Custom rules run before the managed rule sets, lowest priority first:
#   10  RateLimitAuthPaths  100 per IP per 5 minutes on the credential endpoints
#   20  RateLimitPerIP      2000 per IP per 5 minutes, webhooks excluded
# Managed rule sets: Microsoft_DefaultRuleSet 2.1 (OWASP CRS 3.3.2 based,
# SQLi, XSS, LFI, RCE and protocol rules, with Microsoft Threat
# Intelligence rules) and Microsoft_BotManagerRuleSet 1.1 (bad bots blocked,
# unknown bots logged).
resource "azurerm_web_application_firewall_policy" "this" {
  name                = "${var.name_prefix}-waf"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  policy_settings {
    enabled = true
    mode    = local.waf_block ? "Prevention" : "Detection"

    # The body is inspected. Its size is bounded by nginx's
    # client_max_body_size (50m, templates/edge-nginx.conf.tftpl), not by
    # the WAF: request_body_enforcement = false passes larger bodies after
    # inspecting the first request_body_inspect_limit_in_kb, as the AWS
    # stack counts SizeRestrictions_BODY instead of blocking it. Multipart
    # uploads are refused above the same 50 MB nginx allows.
    request_body_check               = true
    request_body_enforcement         = false
    request_body_inspect_limit_in_kb = 128
    max_request_body_size_in_kb      = 2000
    file_upload_enforcement          = true
    file_upload_limit_in_mb          = 50

    # Without scrubbing, the firewall log would hold bearer tokens, session
    # cookies and OAuth code/state query parameters in plain text. The AWS
    # stack redacts the same headers and the query string. Body values are
    # scrubbed too: a matched rule logs the matching value. Scrubbing only
    # affects what is written; the WAF still evaluates the real values.
    log_scrubbing {
      enabled = true
      rule {
        match_variable          = "RequestHeaderNames"
        selector_match_operator = "Equals"
        selector                = "authorization"
      }
      rule {
        match_variable          = "RequestHeaderNames"
        selector_match_operator = "Equals"
        selector                = "cookie"
      }
      rule {
        match_variable          = "RequestCookieNames"
        selector_match_operator = "EqualsAny"
      }
      rule {
        match_variable          = "RequestArgNames"
        selector_match_operator = "EqualsAny"
      }
      rule {
        match_variable          = "RequestPostArgNames"
        selector_match_operator = "EqualsAny"
      }
      rule {
        match_variable          = "RequestJSONArgNames"
        selector_match_operator = "EqualsAny"
      }
    }
  }

  # The api's own login limiters are per replica, so every replica
  # autoscaling adds raises the fleet-wide login budget. This rule sees
  # traffic before it fans out. UrlDecode so an encoded path
  # (/v1/auth/%6Cogin) cannot slip past it.
  custom_rules {
    name                 = "RateLimitAuthPaths"
    priority             = 10
    rule_type            = "RateLimitRule"
    action               = local.waf_custom_action
    rate_limit_duration  = "FiveMins"
    rate_limit_threshold = 100
    group_rate_limit_by  = "ClientAddr"

    match_conditions {
      match_variables {
        variable_name = "RequestUri"
      }
      operator     = "BeginsWith"
      match_values = [for p in local.waf_auth_paths : lower(p)]
      transforms   = ["UrlDecode", "Lowercase"]
    }
  }

  # Global per-IP bound (2000 per 5-minute window): generous for a
  # real user driving the SPA, tight enough to bound one client hammering
  # the api. The condition EXCLUDES the webhook paths. No UrlDecode there on
  # purpose: an encoded webhook path fails the exclusion and is rate limited
  # like everything else, the safe direction.
  custom_rules {
    name                 = "RateLimitPerIP"
    priority             = 20
    rule_type            = "RateLimitRule"
    action               = local.waf_custom_action
    rate_limit_duration  = "FiveMins"
    rate_limit_threshold = 2000
    group_rate_limit_by  = "ClientAddr"

    match_conditions {
      match_variables {
        variable_name = "RequestUri"
      }
      operator           = "BeginsWith"
      negation_condition = true
      match_values       = local.webhook_paths
      transforms         = ["Lowercase"]
    }
  }

  managed_rules {
    # Add exclusions for false positives found in the count phase here, for
    # example a rich-text field that matches an XSS rule:
    #   exclusion {
    #     match_variable          = "RequestArgNames"
    #     selector_match_operator = "Equals"
    #     selector                = "body"
    #     excluded_rule_set {
    #       type    = "Microsoft_DefaultRuleSet"
    #       version = "2.1"
    #       rule_group { rule_group_name = "XSS" excluded_rules = ["941130"] }
    #     }
    #   }
    managed_rule_set {
      type    = "Microsoft_DefaultRuleSet"
      version = "2.1"
    }

    managed_rule_set {
      type    = "Microsoft_BotManagerRuleSet"
      version = "1.1"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-waf", Component = "edge" })
}

# ---- Application Gateway ---------------------------------------------------------------

resource "azurerm_application_gateway" "this" {
  count               = local.appgw_enabled ? 1 : 0
  name                = "${var.name_prefix}-appgw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  zones               = local.appgw_zones

  firewall_policy_id                = azurerm_web_application_firewall_policy.this.id
  force_firewall_policy_association = true
  http2_enabled                     = true

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  autoscale_configuration {
    # One unit kept warm so the first requests after a quiet period are not
    # slowed by a scale-out.
    min_capacity = 1
    max_capacity = 10
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.appgw.id]
  }

  gateway_ip_configuration {
    name      = "gateway"
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_ip_configuration {
    name                 = "public"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = "https"
    port = 443
  }

  frontend_port {
    name = "http"
    port = 80
  }

  ssl_certificate {
    name                = "public"
    key_vault_secret_id = local.public_certificate_secret_id
  }

  # TLS 1.2 minimum with forward-secret ciphers only, the counterpart of the
  # ALB's ELBSecurityPolicy-TLS13-1-2-2021-06.
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101S"
  }

  http_listener {
    name                           = "https"
    frontend_ip_configuration_name = "public"
    frontend_port_name             = "https"
    protocol                       = "Https"
    ssl_certificate_name           = "public"
  }

  http_listener {
    name                           = "http"
    frontend_ip_configuration_name = "public"
    frontend_port_name             = "http"
    protocol                       = "Http"
  }

  redirect_configuration {
    name                 = "http-to-https"
    redirect_type        = "Permanent"
    target_listener_name = "https"
    include_path         = true
    include_query_string = true
  }

  # The api app's ingress. Container Apps routes by host name, so the
  # gateway sends the app's FQDN as Host and SNI; the edge sets the public
  # host again for cmd/api (templates/edge-nginx.conf.tftpl). The
  # environment's certificate for its default domain is publicly trusted, so
  # no trusted root certificate is configured.
  backend_address_pool {
    name  = "api"
    fqdns = [azurerm_container_app.api[0].ingress[0].fqdn]
  }

  backend_http_settings {
    name                                = "api"
    cookie_based_affinity               = "Disabled"
    port                                = 443
    protocol                            = "Https"
    pick_host_name_from_backend_address = true
    # The edge's proxy_read_timeout; MCP answers are single-event streams.
    request_timeout = 120
    probe_name      = "api-healthz"
  }

  # Health probes bypass the WAF. /healthz is proxied by the edge to cmd/api.
  probe {
    name                                      = "api-healthz"
    protocol                                  = "Https"
    path                                      = "/healthz"
    interval                                  = 15
    timeout                                   = 5
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = true
    match {
      status_code = ["200"]
    }
  }

  # X-Forwarded-For becomes the client address alone: the gateway would
  # otherwise append "ip:port" to whatever the client sent. The edge trusts
  # the gateway subnet and takes the rightmost untrusted entry as the client
  # (its auth rate limit, X-Real-IP for cmd/api).
  rewrite_rule_set {
    name = "client-address"
    rewrite_rule {
      name          = "x-forwarded-for"
      rule_sequence = 100
      request_header_configuration {
        header_name  = "X-Forwarded-For"
        header_value = "{var_client_ip}"
      }
    }
  }

  request_routing_rule {
    name                       = "https"
    priority                   = 100
    rule_type                  = "Basic"
    http_listener_name         = "https"
    backend_address_pool_name  = "api"
    backend_http_settings_name = "api"
    rewrite_rule_set_name      = "client-address"
  }

  request_routing_rule {
    name                        = "http-to-https"
    priority                    = 200
    rule_type                   = "Basic"
    http_listener_name          = "http"
    redirect_configuration_name = "http-to-https"
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-appgw", Component = "edge" })

  depends_on = [
    time_sleep.appgw_rbac_propagation,
    azurerm_subnet_network_security_group_association.appgw,
    azurerm_private_dns_a_record.environment,
    azurerm_private_dns_zone_virtual_network_link.environment,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
    azurerm_private_endpoint.key_vault,
  ]
}

# ---- WAF and access log retention ------------------------------------------------------
# The gateway's diagnostic setting (diagnostics.tf) writes to the
# resource-specific tables, kept 30 days, the counterpart of the AWS stack's aws-waf-logs-<name_prefix> log group.
resource "azurerm_log_analytics_workspace_table" "appgw" {
  for_each                = toset(["AGWFirewallLogs", "AGWAccessLogs"])
  name                    = each.key
  workspace_id            = azurerm_log_analytics_workspace.this.id
  retention_in_days       = 30
  total_retention_in_days = 30
}
