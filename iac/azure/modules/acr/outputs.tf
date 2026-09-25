output "login_server" {
  value       = azurerm_container_registry.acr.login_server
  description = "ACR login server hostname (e.g. wttperfacr123456.azurecr.io)"
}

output "registry_name" {
  value       = azurerm_container_registry.acr.name
  description = "Azure Container Registry name"
}

output "registry_id" {
  value       = azurerm_container_registry.acr.id
  description = "Azure Container Registry resource ID"
}

output "pull_dockerconfigjson" {
  value       = azurerm_key_vault_secret.pull_dockerconfigjson.value
  description = "Full dockerconfigjson for Kubernetes imagePullSecret"
  sensitive   = true
}

output "pull_username" {
  value       = azurerm_container_registry_token.pull.name
  description = "Shared read-only ACR token username"
}

output "pull_password" {
  value       = azurerm_container_registry_token_password.pull.password1[0].value
  description = "Shared read-only ACR token password"
  sensitive   = true
}
