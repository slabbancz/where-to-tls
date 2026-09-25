resource "random_password" "admin" {
  count            = var.admin_password == null ? 1 : 0
  length           = 20
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

locals {
  admin_pass = var.admin_password != null ? var.admin_password : random_password.admin[0].result
}

resource "azurerm_windows_virtual_machine_scale_set" "vmss" {
  name                         = "wtt-${var.env}-vm-windows-vmss"
  computer_name_prefix         = "wttwiniis"
  resource_group_name          = var.resource_group_name
  location                     = var.location
  sku                          = var.vm_size
  instances                    = 1
  admin_username               = var.admin_username
  admin_password               = local.admin_pass
  proximity_placement_group_id = var.ppg_id
  zones                        = [var.zone]
  zone_balance                 = false
  upgrade_mode                 = "Manual"
  overprovision                = false
  custom_data                  = base64encode(file("${path.module}/../../../bootstrap/node/configure-windows-ssh.ps1"))
  tags                         = var.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2025-datacenter"
    version   = "26100.33296.260809"
  }

  identity {
    type = "SystemAssigned"
  }

  network_interface {
    name                          = "wtt-${var.env}-vm-windows-nic"
    primary                       = true
    enable_accelerated_networking = true

    ip_configuration {
      name                                   = "wtt-${var.env}-vm-windows-ipconfig"
      primary                                = true
      subnet_id                              = var.subnet_id
      load_balancer_backend_address_pool_ids = [var.backend_address_pool_id, var.outbound_backend_pool_id]
    }
  }

  lifecycle {
    ignore_changes = [admin_username]
  }
}

resource "azurerm_virtual_machine_scale_set_extension" "ssh" {
  name                         = "wtt-${var.env}-vm-windows-ssh"
  virtual_machine_scale_set_id = azurerm_windows_virtual_machine_scale_set.vmss.id
  publisher                    = "Microsoft.Compute"
  type                         = "CustomScriptExtension"
  type_handler_version         = "1.10"
  auto_upgrade_minor_version   = true

  protected_settings = jsonencode({
    commandToExecute = join(" ", [
      "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass",
      "-File C:\\AzureData\\CustomData.bin",
      "-UserName '${var.admin_username}'",
      "-PublicKeyBase64 '${base64encode(var.ssh_public_key)}'",
      "-AllowedSource '${var.vnet_cidr}'",
    ])
  })
}

# Grant VM managed identity access to Key Vault secrets (RBAC)
resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_windows_virtual_machine_scale_set.vmss.identity[0].principal_id
}
