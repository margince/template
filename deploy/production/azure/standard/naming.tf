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

  # The images `make release VERSION=<release_version>` pushes with REGISTRY
  # set to this registry's login server (docs/release.md, Section 6).
  # README.md, "Releases", locks each released tag read-only.
  images = {
    for role in ["api", "worker", "web"] :
    role => "${azurerm_container_registry.this.login_server}/${var.instance_name}/${role}:${var.release_version}"
  }
}
