resource "azurerm_virtual_network" "vnet" {
  name                = "wtt-${var.env}-vnet"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.vnet_address_space
  tags                = var.tags
}

resource "azurerm_proximity_placement_group" "ppg" {
  name                = "wtt-${var.env}-ppg"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_public_ip" "outbound" {
  name                = "wtt-${var.env}-outbound-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_lb" "outbound" {
  name                = "wtt-${var.env}-outbound-lb"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                 = "wtt-${var.env}-outbound-frontend"
    public_ip_address_id = azurerm_public_ip.outbound.id
  }
}

resource "azurerm_lb_backend_address_pool" "outbound" {
  name            = "wtt-${var.env}-outbound-backend-pool"
  loadbalancer_id = azurerm_lb.outbound.id
}

resource "azurerm_lb_outbound_rule" "outbound" {
  name                    = "wtt-${var.env}-outbound-rule"
  loadbalancer_id         = azurerm_lb.outbound.id
  protocol                = "All"
  backend_address_pool_id = azurerm_lb_backend_address_pool.outbound.id

  frontend_ip_configuration {
    name = "wtt-${var.env}-outbound-frontend"
  }
}

# Contract §7 subnets
resource "azurerm_subnet" "clients" {
  name                 = "wtt-${var.env}-client-snet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_prefixes.clients]
}

resource "azurerm_subnet" "client_jumpbox" {
  name                 = "wtt-${var.env}-client-jumpbox-snet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_prefixes.client_jumpbox]

  delegation {
    name = "aci"

    service_delegation {
      name = "Microsoft.ContainerInstance/containerGroups"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action",
      ]
    }
  }
}

resource "azurerm_subnet" "servers" {
  name                 = "wtt-${var.env}-vm-snet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_prefixes.servers]
}

resource "azurerm_subnet" "k8s_cp" {
  name                 = "wtt-${var.env}-k8s-cp-snet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_prefixes.k8s_cp]
}

resource "azurerm_subnet" "k8s_nodes" {
  name                 = "wtt-${var.env}-k8s-nodes-snet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_prefixes.k8s_nodes]
}

# Contract §7: NSGs are deleted entirely. All subnets share one VNet where
# Azure's default AllowVNetInBound permits intra-VNet benchmark and cluster traffic.
# The measured path is private via internal Standard LB and absence of public IPs.
