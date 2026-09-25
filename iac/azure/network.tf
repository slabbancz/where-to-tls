# network.tf — Virtual network, subnets, and proximity placement group (Contract §7)
# NSGs omitted entirely per Contract §7 (intra-VNet traffic relies on AllowVNetInBound defaults).
module "network" {
  source              = "./modules/network"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  env                 = var.env
  tags                = var.tags
}
