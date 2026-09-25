output "key_vault_id" {
  value       = azurerm_key_vault.kv.id
  description = "Key Vault ID"
  depends_on  = [time_sleep.wait_for_rbac]
}

output "key_vault_name" {
  value       = azurerm_key_vault.kv.name
  description = "Key Vault name"
  depends_on  = [time_sleep.wait_for_rbac]
}

output "rbac_ready" {
  value       = time_sleep.wait_for_rbac.id
  description = "Sentinel indicating Key Vault RBAC role assignment has propagated"
}

output "ca_pem" {
  value       = tls_self_signed_cert.ca.cert_pem
  description = "Run CA root certificate PEM (exported for benchmark harness)"
}

output "server_cert_secret_name" {
  value       = azurerm_key_vault_secret.server_cert.name
  description = "Shared server certificate Key Vault secret name"
}

output "server_key_secret_name" {
  value       = azurerm_key_vault_secret.server_key.name
  description = "Shared server private-key Key Vault secret name"
}
