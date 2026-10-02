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

  # The three role images of one instance release, by tag, pulled anonymously
  # from the public registry; the instance's release.yml builds them.
  images = {
    for role in ["api", "worker", "web"] : role => "${var.image_repo}/${role}:${var.release_version}"
  }
}
