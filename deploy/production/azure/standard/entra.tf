# Entra ID: Margince reuses the customer's existing tenant, the same way their
# Dataverse environment does.
#
#   Who may sign in   one enterprise app with "assignment required", assigned
#                     the SAME security group that gates Dataverse, so Entra
#                     refuses to issue a token to anyone outside it.
#   MFA, device, etc. the customer's existing Conditional Access policy, with
#                     this app added to it (a manual step, README.md: this
#                     stack never edits a CA policy it does not own).
#   Staff sign-in     Margince's own Microsoft OIDC login
#                     (/v1/auth/oidc/microsoft/*), pinned to this tenant by
#                     MARGINCE_MICROSOFT_SIGNIN_TENANT.
#   Mailbox capture   the Graph connector, same app and secret
#                     (MARGINCE_GRAPH_CLIENT_ID/SECRET, cmd/api/config.go).
#   Admin consent     granted by an Entra admin in the portal (README.md,
#                     step 2), so the Terraform identity needs Application
#                     Administrator and nothing more privileged.
#
# Dataverse's own server-to-server access does not go through this app: it
# uses the managed identity in identity.tf (dataverse), registered in
# Dataverse as an application user.

data "azuread_client_config" "current" {}

data "azuread_application_published_app_ids" "well_known" {}

data "azuread_service_principal" "msgraph" {
  client_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
}

locals {
  # Delegated Graph permissions, each with the code that asks for it:
  #   openid, email, profile           Microsoft sign-in (identity/ssologin.go)
  #   offline_access, User.Read,
  #   Mail.Read, Mail.Send             mail capture and send (compose/capture.go graphScopes)
  #   Calendars.Read                   calendar capture (capture/graphcal/client.go)
  graph_delegated_scopes = ["openid", "email", "profile", "offline_access", "User.Read", "Mail.Read", "Mail.Send", "Calendars.Read"]

  # Every OAuth callback the api serves under public_base_url.
  entra_redirect_uris = [
    "${var.public_base_url}/v1/auth/oidc/microsoft/callback",
    "${var.public_base_url}/v1/connectors/graph/callback",
    "${var.public_base_url}/v1/connectors/graphcal/callback",
  ]

  entra_client_id = azuread_application.margince.client_id
  entra_tenant_id = data.azuread_client_config.current.tenant_id

  # Terraform replaces the client secret on the first apply after this many
  # days; plan an apply before it expires (it is valid 30 days longer).
  entra_secret_rotation_days = 180
}

resource "azuread_application" "margince" {
  display_name     = "Margince (${var.name_prefix})"
  owners           = [data.azuread_client_config.current.object_id]
  sign_in_audience = "AzureADMyOrg" # this tenant only

  web {
    redirect_uris = local.entra_redirect_uris
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  required_resource_access {
    resource_app_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]

    dynamic "resource_access" {
      for_each = local.graph_delegated_scopes
      content {
        id   = data.azuread_service_principal.msgraph.oauth2_permission_scope_ids[resource_access.value]
        type = "Scope"
      }
    }
  }

}

resource "azuread_service_principal" "margince" {
  client_id = azuread_application.margince.client_id
  owners    = [data.azuread_client_config.current.object_id]

  # "Assignment required": only principals assigned below (the security group)
  # can get a token for this app. Everyone else is refused by Entra itself,
  # before Margince sees a request.
  app_role_assignment_required = true

  feature_tags {
    enterprise = true
  }
}

resource "azuread_app_role_assignment" "access_group" {
  app_role_id         = "00000000-0000-0000-0000-000000000000" # default access, no app roles defined
  principal_object_id = var.entra_access_group_object_id
  resource_object_id  = azuread_service_principal.margince.object_id
}

resource "time_rotating" "entra_secret" {
  rotation_days = local.entra_secret_rotation_days
}

resource "azuread_application_password" "margince" {
  application_id = azuread_application.margince.id
  display_name   = "terraform (${var.name_prefix})"
  # Valid a little longer than the rotation period, so the apply that rotates
  # it has room to happen late without an outage.
  end_date_relative = "${(local.entra_secret_rotation_days + 30) * 24}h"

  rotate_when_changed = {
    rotation = time_rotating.entra_secret.id
  }

  # The new secret exists before the old one is removed; the Key Vault
  # secret's new version then rolls a new app revision
  # (MARGINCE_SECRET_GENERATION, containerapps.tf), so sign-in never breaks.
  lifecycle {
    create_before_destroy = true
  }
}
