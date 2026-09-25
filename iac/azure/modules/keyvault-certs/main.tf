data "azurerm_client_config" "current" {}

resource "random_string" "kv_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_key_vault" "kv" {
  name                       = "wtt-${var.env}-kv${random_string.kv_suffix.result}"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  tags                       = var.tags
}

# Deploying identity gets Secrets Officer to populate initial certs
resource "azurerm_role_assignment" "deployer_secrets_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Azure RBAC propagation delay to prevent 403 ForbiddenByRbac races
resource "time_sleep" "wait_for_rbac" {
  create_duration = "60s"

  triggers = {
    role_assignment_id = azurerm_role_assignment.deployer_secrets_officer.id
  }

  depends_on = [azurerm_role_assignment.deployer_secrets_officer]
}

# ------------------------------------------------------------------------------
# Certificate Authority: ECDSA P-256 self-signed root
# ------------------------------------------------------------------------------
resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem = tls_private_key.ca.private_key_pem

  subject {
    common_name  = "wtt-benchmark-ca"
    organization = "Where-To-TLS Benchmark Run"
  }

  validity_period_hours = 8760
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature"
  ]
}

# ------------------------------------------------------------------------------
# Shared leaf certificate: ECDSA P-256 signed by the run CA.
# Every TLS endpoint uses this leaf so the certificate handshake bytes match.
# ------------------------------------------------------------------------------
resource "tls_private_key" "leaf" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "leaf" {
  private_key_pem = tls_private_key.leaf.private_key_pem

  subject {
    common_name  = var.tls_dns_names[0]
    organization = "Where-To-TLS Benchmark"
  }

  dns_names = concat(var.tls_dns_names, [
    "localhost",
    "*.${var.dns_zone}",
    "*.default.svc.cluster.local"
  ])

  ip_addresses = [
    "127.0.0.1"
  ]
}

resource "tls_locally_signed_cert" "leaf" {
  cert_request_pem   = tls_cert_request.leaf.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = 8760

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth"
  ]
}

# ------------------------------------------------------------------------------
# Azure Key Vault Secrets Storage
# ------------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "ca_cert" {
  name         = "ca-cert-pem"
  value        = tls_self_signed_cert.ca.cert_pem
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.wait_for_rbac]
}

resource "azurerm_key_vault_secret" "server_cert" {
  name         = "wtt-server-cert"
  value        = "${tls_locally_signed_cert.leaf.cert_pem}\n${tls_self_signed_cert.ca.cert_pem}"
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.wait_for_rbac]
}

resource "azurerm_key_vault_secret" "server_key" {
  name         = "wtt-server-key"
  value        = tls_private_key.leaf.private_key_pem_pkcs8
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.wait_for_rbac]
}

resource "azurerm_key_vault_secret" "ssh_public_key" {
  name         = "wtt-ssh-public-key"
  value        = var.ssh_public_key
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.wait_for_rbac]
}

resource "azurerm_key_vault_secret" "ssh_private_key" {
  count        = var.store_ssh_private_key ? 1 : 0
  name         = "wtt-ssh-private-key"
  value        = var.ssh_private_key
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.wait_for_rbac]
}

# Export CA root to results/ca.pem for benchmark harness trust store
resource "local_file" "ca_pem" {
  content  = tls_self_signed_cert.ca.cert_pem
  filename = "${path.root}/../../results/ca.pem"
}
