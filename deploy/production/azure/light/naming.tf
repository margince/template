# Globally unique names. Key vaults, Postgres servers and public IP DNS labels
# share a namespace across Azure (per region for DNS labels), and a
# soft-deleted key vault name stays reserved for its retention period, so each
# such name carries a short random suffix chosen once per stack.
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

  # The public host: the operator's own hostname, or the Azure DNS label of
  # the VM's public IP (<label>.<region>.cloudapp.azure.com), which resolves
  # as soon as the IP exists and which Let's Encrypt can certify.
  dns_label       = var.dns_label != "" ? var.dns_label : local.global_prefix
  azure_fqdn      = "${local.dns_label}.${var.azure_region}.cloudapp.azure.com"
  public_host     = var.public_hostname != "" ? var.public_hostname : local.azure_fqdn
  public_base_url = "https://${local.public_host}"
}
