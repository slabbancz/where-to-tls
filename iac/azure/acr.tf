# acr.tf — Azure Container Registry (Contract §4: Basic SKU, repository-scoped token)
module "acr" {
  source              = "./modules/acr"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  env                 = var.env
  key_vault_id        = module.keyvault_certs.key_vault_id
  tags                = var.tags

  depends_on = [module.keyvault_certs]
}
