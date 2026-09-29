# Premium SKU is this stack's one deliberate cost increase over the cheapest
# option — every other service here defaults to the cheapest SKU that still
# hits the managed-service/security bar (variables.tf's own comments explain
# each one). ACR is the exception because Premium is the ONLY tier that
# supports two things everything else in this stack already has: a private
# endpoint (privateendpoints.tf) and a customer-managed key (below). Basic/
# Standard ACR would make this the one public-endpoint, platform-key
# exception in a stack that private-networks and CMK-encrypts everything
# else — Premium buys back posture consistency, at Premium's own list price.
resource "azurerm_container_registry" "this" {
  name                = "${local.flat_prefix}${local.suffix}acr"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Premium"
  admin_enabled       = false

  # Public endpoint only while operator_ip_allowlist is set, so a laptop can
  # push images (scripts/build-images.sh local); default-deny lets in nothing
  # else, and pulls from Container Apps keep using the private endpoint.
  public_network_access_enabled = length(var.operator_ip_allowlist) > 0
  network_rule_set = [{
    default_action = "Deny"
    ip_rule = [for ip in var.operator_ip_allowlist : {
      action   = "Allow"
      ip_range = "${ip}/32"
    }]
  }]
  # Routes the registry's own underlying blob-layer traffic (image layers,
  # not just the control-plane API) through the private endpoint below too —
  # Premium-only, and specifically documented as needed once a registry sits
  # behind Private Link, or pulls fall back to ACR's regional public data
  # endpoint for the layer bytes even though the control-plane call went
  # private.
  data_endpoint_enabled = true

  # Customer-managed key only when registry_customer_managed_key is set (off
  # by default, variables.tf): images are not customer data, and ACR documents
  # firewalled-vault key access for a system-assigned identity only.
  dynamic "identity" {
    for_each = var.registry_customer_managed_key ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [azurerm_user_assigned_identity.data_cmk.id]
    }
  }

  dynamic "encryption" {
    for_each = var.registry_customer_managed_key ? [1] : []
    content {
      key_vault_key_id   = azurerm_key_vault_key.data.versionless_id
      identity_client_id = azurerm_user_assigned_identity.data_cmk.client_id
    }
  }

  # Untagged-manifest cleanup only (Premium-only). ACR has two known gaps that
  # Terraform cannot close:
  #   - No lifecycle rule to keep only the N most recent tagged images, so the
  #     number of released images kept for rollback is unbounded.
  #   - No control-plane setting for immutable tags. ACR tag locking
  #     (`az acr repository update --write-enabled false`) is a data-plane
  #     operation on an existing tag, not something this resource exposes.
  # An operator who needs tag immutability or a release-count bound does it by
  # hand per push, or scripts it outside Terraform.
  retention_policy_in_days = var.acr_untagged_manifest_retention_days

  # Not enabled: quarantine_policy_enabled is superseded by Microsoft Defender
  # for Cloud's container image scanning, a subscription-level Defender plan
  # setting rather than a property of this resource, so out of scope here.

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-acr", Component = "container-registry" })

  depends_on = [azurerm_role_assignment.data_cmk_key_vault_crypto_user]
}
