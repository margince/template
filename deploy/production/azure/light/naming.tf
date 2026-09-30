# Key vault names share one namespace across Azure, and a soft-deleted vault
# name stays reserved for its retention period. The vault name therefore
# carries a short random suffix, chosen once per stack.
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  global_prefix = "${var.name_prefix}-${random_string.suffix.result}"

  # Fixed settings. Change them here if you really need to.
  resource_group_name = "${var.name_prefix}-light"
  vnet_cidr           = "10.30.0.0/16"
  admin_username      = "azureadmin" # passwordless sudo, which make host-bootstrap needs
  os_disk_gb          = 30
  data_disk_type      = "StandardSSD_LRS"

  common_tags = {
    Project   = "margince"
    Flavour   = "light"
    Stack     = var.name_prefix
    ManagedBy = "terraform"
  }

  public_base_url = "https://${var.domain}"
}
