resource "random_string" "acr_suffix" {
  length  = 6
  special = false
  upper   = false
}

# Azure Container Registry (Contract §4: Basic SKU, admin user disabled, public endpoint)
resource "azurerm_container_registry" "acr" {
  name                = "wtt${var.env}acr${random_string.acr_suffix.result}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = var.tags
}

# Registry-wide read-only scope used by all image consumers.
resource "azurerm_container_registry_scope_map" "pull" {
  name                    = "wtt-${var.env}-acr-pull-scope"
  container_registry_name = azurerm_container_registry.acr.name
  resource_group_name     = var.resource_group_name
  actions = [
    "repositories/*/content/read",
    "repositories/*/metadata/read"
  ]
}

# Registry-wide read-only token used by application hosts, Kubernetes, and the jumpbox.
resource "azurerm_container_registry_token" "pull" {
  name                    = "wtt-${var.env}-acr-pull-token"
  container_registry_name = azurerm_container_registry.acr.name
  resource_group_name     = var.resource_group_name
  scope_map_id            = azurerm_container_registry_scope_map.pull.id
}

resource "azurerm_container_registry_token_password" "pull" {
  container_registry_token_id = azurerm_container_registry_token.pull.id

  password1 {}
}

# Docker credential consumed by pull-only clients.
resource "azurerm_key_vault_secret" "pull_dockerconfigjson" {
  name = "acr-pull-dockerconfigjson"
  value = jsonencode({
    auths = {
      (azurerm_container_registry.acr.login_server) = {
        username = azurerm_container_registry_token.pull.name
        password = azurerm_container_registry_token_password.pull.password1[0].value
        auth     = base64encode("${azurerm_container_registry_token.pull.name}:${azurerm_container_registry_token_password.pull.password1[0].value}")
      }
    }
  })
  key_vault_id = var.key_vault_id
}

# Registry-wide read/write scope used by publishers.
resource "azurerm_container_registry_scope_map" "push" {
  name                    = "wtt-${var.env}-acr-push-scope"
  container_registry_name = azurerm_container_registry.acr.name
  resource_group_name     = var.resource_group_name
  actions = [
    "repositories/*/content/read",
    "repositories/*/content/write",
    "repositories/*/metadata/read",
    "repositories/*/metadata/write"
  ]
}

resource "azurerm_container_registry_token" "push" {
  name                    = "wtt-${var.env}-acr-push-token"
  container_registry_name = azurerm_container_registry.acr.name
  resource_group_name     = var.resource_group_name
  scope_map_id            = azurerm_container_registry_scope_map.push.id
}

resource "azurerm_container_registry_token_password" "push" {
  container_registry_token_id = azurerm_container_registry_token.push.id

  password1 {}
}

resource "azurerm_key_vault_secret" "push_dockerconfigjson" {
  name = "acr-push-dockerconfigjson"
  value = jsonencode({
    auths = {
      (azurerm_container_registry.acr.login_server) = {
        username = azurerm_container_registry_token.push.name
        password = azurerm_container_registry_token_password.push.password1[0].value
        auth     = base64encode("${azurerm_container_registry_token.push.name}:${azurerm_container_registry_token_password.push.password1[0].value}")
      }
    }
  })
  key_vault_id = var.key_vault_id
}

moved {
  from = azurerm_key_vault_secret.dockerconfigjson
  to   = azurerm_key_vault_secret.pull_dockerconfigjson
}

moved {
  from = azurerm_container_registry_scope_map.benchmark_results
  to   = azurerm_container_registry_scope_map.push
}

moved {
  from = azurerm_container_registry_token.benchmark_results
  to   = azurerm_container_registry_token.push
}

moved {
  from = azurerm_container_registry_token_password.benchmark_results
  to   = azurerm_container_registry_token_password.push
}

moved {
  from = azurerm_key_vault_secret.benchmark_results_dockerconfigjson
  to   = azurerm_key_vault_secret.push_dockerconfigjson
}
