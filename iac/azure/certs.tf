# One SSH key is shared by every VMSS. An externally supplied public key remains
# supported; otherwise OpenTofu writes the generated private key only to results/.
resource "tls_private_key" "shared_ssh" {
  count     = var.ssh_public_key == null ? 1 : 0
  algorithm = "ED25519"
}

locals {
  shared_ssh_public_key  = var.ssh_public_key != null ? var.ssh_public_key : tls_private_key.shared_ssh[0].public_key_openssh
  shared_ssh_private_key = var.ssh_public_key == null ? tls_private_key.shared_ssh[0].private_key_openssh : null
}

resource "local_sensitive_file" "shared_ssh_private_key" {
  count           = var.ssh_public_key == null ? 1 : 0
  content         = tls_private_key.shared_ssh[0].private_key_openssh
  filename        = "${path.root}/../../results/id_ed25519"
  file_permission = "0600"
}

# certs.tf — Key Vault & TLS Certificates module (Run CA + per-scenario leaf certs in Key Vault)
module "keyvault_certs" {
  source                = "./modules/keyvault-certs"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = var.location
  env                   = var.env
  dns_zone              = var.dns_zone
  ssh_public_key        = local.shared_ssh_public_key
  ssh_private_key       = local.shared_ssh_private_key
  store_ssh_private_key = var.ssh_public_key == null
  tls_dns_names = [
    "c0-vm-only.${var.dns_zone}",
    "s1-iis-netfx.${var.dns_zone}",
    "s2-vm-net.${var.dns_zone}",
    "s2-vm-java.${var.dns_zone}",
    "s2-vm-go.${var.dns_zone}",
    "s2-vm-rust.${var.dns_zone}",
    "s4-k8s-pod-net.${var.dns_zone}",
    "s4-k8s-pod-java.${var.dns_zone}",
    "s4-k8s-pod-go.${var.dns_zone}",
    "s4-k8s-pod-rust.${var.dns_zone}",
    "s5-traefik-passthrough-net.${var.dns_zone}",
    "s5-traefik-passthrough-java.${var.dns_zone}",
    "s5-traefik-passthrough-go.${var.dns_zone}",
    "s5-traefik-passthrough-rust.${var.dns_zone}",
    "s6-traefik-terminate-net.${var.dns_zone}",
    "s6-traefik-terminate-java.${var.dns_zone}",
    "s6-traefik-terminate-go.${var.dns_zone}",
    "s6-traefik-terminate-rust.${var.dns_zone}"
  ]
  tags = var.tags
}
