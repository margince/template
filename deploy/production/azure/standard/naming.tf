# Globally unique names. Storage accounts, key vaults
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

  # The Margince source release publishes these three digest-pinned artifacts.
  # Azure consumes them unchanged; image creation remains owned by the source.
  images                      = var.image_refs
  source_registry_credentials = var.source_registry_username != ""
  source_registry_server      = split("/", var.image_refs.api)[0]
}
