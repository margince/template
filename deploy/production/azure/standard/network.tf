data "azurerm_client_config" "current" {}

# azurerm has no provider-level default_tags block (versions.tf), so every
# resource merges this map into its own tags.
locals {
  common_tags = {
    Project   = "margince"
    Flavour   = "standard"
    ManagedBy = "terraform"
    Stack     = var.name_prefix
  }

  vnet_cidr = "10.20.0.0/16"
}

resource "azurerm_resource_group" "this" {
  name     = var.name_prefix
  location = var.azure_region
  tags     = local.common_tags
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.name_prefix}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [local.vnet_cidr]
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-vnet" })
}

# ---- Subnets -----------------------------------------------------------------
# Azure subnets are regional, not zone-scoped, so one subnet per tier covers
# every zone. Zone placement is set on the resources themselves (postgres.tf's
# zone, containerapps.tf's zone_redundancy_enabled). Four tiers here: appgw,
# containerapps, postgres and private_endpoints (jumpbox.tf adds ops). The
# config share has no subnet of its own; it is reached through the storage
# private endpoints (see privateendpoints.tf).

resource "azurerm_subnet" "appgw" {
  # Dedicated /24 for the Application Gateway (appgw.tf): v2 needs a subnet
  # that holds nothing else, and a /24 leaves room for autoscaling to its
  # maximum instance count. No NAT gateway: the gateway's
  # outbound traffic uses its own public IP.
  name                 = "${var.name_prefix}-appgw"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(local.vnet_cidr, 8, 0)]
}

resource "azurerm_subnet" "containerapps" {
  # /23: more than the /27 a workload profiles environment needs
  # (containerapps.tf), kept so the subnet is not replaced and so the
  # environment has room to scale out replicas.
  name                 = "${var.name_prefix}-containerapps"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(local.vnet_cidr, 7, 1)]

  delegation {
    name = "containerapps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "postgres" {
  # Delegated-subnet VNet integration, not a private endpoint: the provider's
  # documented standard mode for Flexible Server (see postgres.tf).
  name                 = "${var.name_prefix}-postgres"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(local.vnet_cidr, 8, 4)]

  delegation {
    name = "postgres"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  # Shared by every azurerm_private_endpoint in this stack (storage blob and
  # file, Key Vault, ACR; privateendpoints.tf). Private endpoints need
  # no subnet exclusivity, and all are reached by the same caller
  # (containerapps), so one subnet is enough.
  name                 = "${var.name_prefix}-private-endpoints"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(local.vnet_cidr, 8, 5)]

  # Makes the private_endpoints NSG apply to private endpoint traffic (off by
  # default for private endpoint subnets).
  private_endpoint_network_policies = "Enabled"
}

# ---- NAT egress ----------------------------------------------------------
# The api and worker containers call public internet endpoints (AI provider
# APIs, Nominatim, VIES, crt.sh, OAuth token endpoints, license validation,
# outbound mail), and the redis app pulls its image from Docker Hub. Postgres,
# Storage, Key Vault and ACR are reached over private endpoints or VNet
# integration. The NAT gateway therefore attaches to the containerapps subnet
# (and the ops subnet, jumpbox.tf).
#
# Known gap: this NAT gateway is not zone-redundant. A Standard-SKU NAT
# Gateway sits in at most one zone. The StandardV2 SKU is documented as
# zone-redundant in a single resource, but its GA status and regional
# availability were not confirmed, so it is not the default. If you need
# zone-resilient egress, evaluate StandardV2 first rather than adding one
# Standard NAT gateway per zone behind new zone-pinned subnets. The Container
# Apps environment is zone-redundant. Postgres is zone-redundant only with
# db_zone_redundant_ha = true (off by default), and Redis is one replica.
resource "azurerm_public_ip" "nat" {
  name                = "${var.name_prefix}-nat"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-nat", Component = "network" })
}

resource "azurerm_nat_gateway" "this" {
  name                = "${var.name_prefix}-nat"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku_name            = "Standard"
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-nat", Component = "network" })
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "containerapps" {
  subnet_id      = azurerm_subnet.containerapps.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

# ---- Network security groups ------------------------------------------------
# One per tier, deny by default: inbound rules name the allowed traffic, and
# outbound is narrowed to what the tier actually originates. NSGs attach to
# subnets, since private endpoints and the Postgres delegated subnet have no
# per-resource NIC to attach one to.

resource "azurerm_network_security_group" "containerapps" {
  name                = "${var.name_prefix}-containerapps"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-containerapps", Component = "network" })

  # The environment is internal (containerapps.tf): its load balancer has a
  # private IP in this subnet, and the only caller from outside the subnet
  # is the Application Gateway, over HTTPS. Nothing from the internet is
  # allowed in.
  security_rule {
    name                       = "AllowHttpsFromAppGateway"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = azurerm_subnet.appgw.address_prefixes[0]
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAzureLoadBalancerInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # Required by Container Apps: components inside the environment's subnet
  # talk to each other, including api and worker to the redis app on 6379 (learn.microsoft.com/azure/container-apps/firewall-integration).
  security_rule {
    name                       = "AllowSubnetInternal"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = azurerm_subnet.containerapps.address_prefixes[0]
    destination_address_prefix = azurerm_subnet.containerapps.address_prefixes[0]
  }

  # Deny by default inside the VNet: without this, the built-in
  # AllowVnetInBound rule lets every subnet reach this one on any port.
  security_rule {
    name                       = "DenyVnetInBound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }
}

resource "azurerm_subnet_network_security_group_association" "containerapps" {
  subnet_id                 = azurerm_subnet.containerapps.id
  network_security_group_id = azurerm_network_security_group.containerapps.id
}

resource "azurerm_network_security_group" "postgres" {
  name                = "${var.name_prefix}-postgres"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-postgres", Component = "database" })

  security_rule {
    name                       = "AllowPostgresFromContainerApps"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = azurerm_subnet.containerapps.address_prefixes[0]
    destination_address_prefix = "*"
  }

  # The jumpbox runs the one-time database bootstrap.
  security_rule {
    name                       = "AllowPostgresFromOps"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = cidrsubnet(local.vnet_cidr, 8, 6)
    destination_address_prefix = "*"
  }

  # Postgres ZoneRedundant HA (db_zone_redundant_ha) replicates between the
  # primary and the standby inside this delegated subnet.
  security_rule {
    name                       = "AllowPostgresSubnetInternal"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = cidrsubnet(local.vnet_cidr, 8, 4)
    destination_address_prefix = cidrsubnet(local.vnet_cidr, 8, 4)
  }

  # Deny by default inside the VNet: without this, the built-in
  # AllowVnetInBound rule lets every subnet reach this one on any port.
  security_rule {
    name                       = "DenyVnetInBound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }
}

resource "azurerm_subnet_network_security_group_association" "postgres" {
  subnet_id                 = azurerm_subnet.postgres.id
  network_security_group_id = azurerm_network_security_group.postgres.id
}

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "${var.name_prefix}-private-endpoints"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-private-endpoints", Component = "network" })

  security_rule {
    name                       = "AllowHttpsFromContainerApps"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = azurerm_subnet.containerapps.address_prefixes[0]
    destination_address_prefix = "*"
  }

  # The jumpbox reads Key Vault and storage
  # over their private endpoints.
  security_rule {
    name                       = "AllowHttpsFromOps"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = cidrsubnet(local.vnet_cidr, 8, 6)
    destination_address_prefix = "*"
  }

  # The Application Gateway reads the public certificate from Key Vault over
  # its private endpoint (appgw.tf).
  security_rule {
    name                       = "AllowHttpsFromAppGateway"
    priority                   = 125
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = azurerm_subnet.appgw.address_prefixes[0]
    destination_address_prefix = "*"
  }

  # Azure Files (config and attachments shares) over SMB.
  security_rule {
    name                       = "AllowSmbFromContainerApps"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "445"
    source_address_prefix      = azurerm_subnet.containerapps.address_prefixes[0]
    destination_address_prefix = "*"
  }

  # Deny by default inside the VNet: without this, the built-in
  # AllowVnetInBound rule lets every subnet reach this one on any port.
  security_rule {
    name                       = "DenyVnetInBound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# Application Gateway v2 subnet rules (learn.microsoft.com/azure/
# application-gateway/configuration-infrastructure): the listener ports from
# the internet, the GatewayManager ports 65200-65535 and the Azure load
# balancer probe are required. Outbound stays at the defaults, which the
# gateway needs.
resource "azurerm_network_security_group" "appgw" {
  name                = "${var.name_prefix}-appgw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-appgw", Component = "network" })

  security_rule {
    name                       = "AllowHttpsInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHttpInboundForRedirectOnly"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowGatewayManagerInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAzureLoadBalancerInbound"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # Deny by default inside the VNet: without this, the built-in
  # AllowVnetInBound rule lets every subnet reach this one on any port.
  security_rule {
    name                       = "DenyVnetInBound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }
}

resource "azurerm_subnet_network_security_group_association" "appgw" {
  subnet_id                 = azurerm_subnet.appgw.id
  network_security_group_id = azurerm_network_security_group.appgw.id
}

# ---- Observability sink -----------------------------------------------------
# One Log Analytics workspace for the whole stack. The Container Apps
# environment sends its logs here directly; Postgres, Key Vault and
# storage send theirs through diagnostic settings.
resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.name_prefix}-logs"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 90
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-logs", Component = "observability" })
}

# ---- VNet flow logs --------------------------------------------------------------
# VNet flow logs replace the retired NSG flow logs. Azure allows one Network
# Watcher per region and creates NetworkWatcher_<region> in NetworkWatcherRG
# with the first VNet, so the flow log is attached to that watcher rather than
# a new one. Kept 90 days, with traffic analytics into Log Analytics. Network Watcher is a trusted service, so it writes through the
# storage account's firewall (AzureServices bypass, storage.tf).
resource "azurerm_network_watcher_flow_log" "vnet" {
  name                 = "${var.name_prefix}-vnet"
  network_watcher_name = "NetworkWatcher_${var.azure_region}"
  resource_group_name  = "NetworkWatcherRG"
  location             = azurerm_resource_group.this.location
  target_resource_id   = azurerm_virtual_network.this.id
  storage_account_id   = azurerm_storage_account.this.id
  enabled              = true
  version              = 2

  retention_policy {
    enabled = true
    days    = 90
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = azurerm_log_analytics_workspace.this.workspace_id
    workspace_region      = azurerm_log_analytics_workspace.this.location
    workspace_resource_id = azurerm_log_analytics_workspace.this.id
    interval_in_minutes   = 10
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-vnet-flow-log", Component = "network" })

  depends_on = [azurerm_virtual_network.this]
}
