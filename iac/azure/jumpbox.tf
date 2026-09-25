# A deliberately minimal private diagnostics container. It is not part of any
# benchmark path and receives no public address, diagnostic settings, or logs.
resource "azurerm_container_group" "client_jumpbox" {
  count               = var.client_jumpbox_enabled ? 1 : 0
  name                = "wtt-${var.env}-client-jumpbox"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  os_type             = "Linux"
  restart_policy      = "Never"
  ip_address_type     = "Private"
  subnet_ids          = [module.network.subnet_client_jumpbox_id]
  tags                = var.tags

  image_registry_credential {
    server   = module.acr.login_server
    username = module.acr.pull_username
    password = module.acr.pull_password
  }

  container {
    name   = "jumpbox"
    image  = "${module.acr.login_server}/wtt/${var.client_jumpbox_image}"
    cpu    = 0.1
    memory = 0.3

    # Azure requires a port declaration for private-IP container groups.
    # listens on nothing; port 1 is deliberately unused and VNet-private.
    ports {
      port     = 1
      protocol = "TCP"
    }

    commands = [
      "/bin/sh",
      "-c",
      <<-SCRIPT
      set -eu
      apk add --no-cache openssh-client
      mkdir -p /root/.ssh
      cp /run/wtt-secrets/id_ed25519 /root/.ssh/id_ed25519
      chmod 0600 /root/.ssh/id_ed25519
      trap : TERM INT
      sleep 2147483647 & wait
      SCRIPT
    ]

    volume {
      name       = "ssh-key"
      mount_path = "/run/wtt-secrets"
      read_only  = true
      secret = {
        id_ed25519 = base64encode(local.shared_ssh_private_key)
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.ssh_public_key == null
      error_message = "client_jumpbox_enabled requires an OpenTofu-generated SSH key so its private half can be retrieved from Key Vault."
    }
  }
}
