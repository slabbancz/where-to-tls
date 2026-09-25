locals {
  cloud_init_content = templatefile("${path.module}/../../../bootstrap/cloud-init/linux-app.yaml.tftpl", {
    key_vault_name            = var.key_vault_name
    admin_username            = var.admin_username
    configure_ssh_script      = file("${path.module}/../../../bootstrap/node/configure-linux-ssh.sh")
    get_identity_token_script = file("${path.module}/../../../bootstrap/cloud/azure/get-identity-token.sh")
    get_secret_script         = file("${path.module}/../../../bootstrap/cloud/azure/get-secret.sh")
  })
}

resource "azurerm_linux_virtual_machine_scale_set" "vmss" {
  name                         = "wtt-${var.env}-vm-linux-vmss"
  resource_group_name          = var.resource_group_name
  location                     = var.location
  sku                          = var.vm_size
  instances                    = 1
  admin_username               = var.admin_username
  proximity_placement_group_id = var.ppg_id
  zones                        = [var.zone]
  zone_balance                 = false
  upgrade_mode                 = "Manual"
  overprovision                = false
  custom_data                  = base64encode(local.cloud_init_content)
  tags                         = var.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-26_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  network_interface {
    name                          = "wtt-${var.env}-vm-linux-nic"
    primary                       = true
    enable_accelerated_networking = true

    ip_configuration {
      name                                   = "wtt-${var.env}-vm-linux-ipconfig"
      primary                                = true
      subnet_id                              = var.subnet_id
      load_balancer_backend_address_pool_ids = [var.backend_address_pool_id, var.outbound_backend_pool_id]
    }
  }

  lifecycle {
    ignore_changes = [admin_username]
  }
}

# Grant VM managed identity access to Key Vault secrets (RBAC)
resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine_scale_set.vmss.identity[0].principal_id
}
