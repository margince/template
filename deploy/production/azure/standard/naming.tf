# Globally unique names. Storage accounts, registries, key vaults
# and Postgres servers share one namespace across all of Azure, and a purged
# key vault name stays reserved for 90 days, so every such name carries a
# short random suffix chosen once per stack.
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  suffix        = random_string.suffix.result
  flat_prefix   = replace(var.name_prefix, "-", "")
  global_prefix = "${var.name_prefix}-${local.suffix}"

  # Images by digest when image_digests names one (immutable), otherwise by
  # image_tag (locked read-only by the build scripts after push).
  images = {
    for role in ["api", "worker", "web"] : role => (
      lookup(var.image_digests, role, "") != ""
      ? "${azurerm_container_registry.this.login_server}/${role}@${var.image_digests[role]}"
      : "${azurerm_container_registry.this.login_server}/${role}:${var.image_tag}"
    )
  }
}
