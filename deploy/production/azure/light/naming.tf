# Key vault names share one namespace across Azure, and a soft-deleted vault
# name stays reserved for its retention period. The vault name therefore
# carries a short random suffix, chosen once per stack.
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  suffix        = random_string.suffix.result
  global_prefix = "${var.name_prefix}-${local.suffix}"

  common_tags = {
    Project     = "margince"
    Flavour     = "light"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  public_base_url = "https://${var.domain}"
}
