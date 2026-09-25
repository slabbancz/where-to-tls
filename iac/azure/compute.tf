# compute.tf — Server VMs (Linux/Windows) and dedicated client load-generator VM (Contract §1a & §7)

locals {
  # c0-cluster-only and c0-vm-only deploy no client VM (Contract §1)
  needs_client_vm = !contains(["c0-cluster-only", "c0-vm-only"], var.active_scenario)

  # Client VM cloud-init (Contract §7: k6, runner, trust run CA, /etc/hosts)
  client_cloud_init = local.needs_client_vm ? templatefile("${path.module}/../bootstrap/cloud-init/client.yaml.tftpl", {
    ca_pem                             = module.keyvault_certs.ca_pem
    lb_ip                              = length(module.lb) > 0 ? module.lb[0].frontend_ip_address : ""
    dns_zone                           = var.dns_zone
    key_vault_name                     = module.keyvault_certs.key_vault_name
    acr_login_server                   = module.acr.login_server
    admin_username                     = var.admin_username
    configure_client_script            = file("${path.module}/../bootstrap/node/configure-client.sh")
    configure_ssh_script               = file("${path.module}/../bootstrap/node/configure-linux-ssh.sh")
    run_benchmark_script               = file("${path.module}/../bootstrap/k6/bench-entry.sh")
    bench_run_script                   = file("${path.module}/../bootstrap/k6/bench-runner.sh")
    bench_publish_script               = file("${path.module}/../bootstrap/k6/bench-publish.sh")
    k6_main_script                     = file("${path.module}/../bootstrap/k6/main.js")
    configure_client_source_ips_script = file("${path.module}/../bootstrap/node/configure-client-source-ips.sh")
    client_source_ip_count             = var.client_source_ip_count
    get_identity_token_script          = file("${path.module}/../bootstrap/cloud/azure/get-identity-token.sh")
    get_secret_script                  = file("${path.module}/../bootstrap/cloud/azure/get-secret.sh")
  }) : ""
}

# Scenario s1: Windows Server 2025 Azure Edition + IIS + ASP.NET 4.8
module "vm_windows_iis" {
  count                    = local.is_windows_vm ? 1 : 0
  source                   = "./modules/vm-windows-iis"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = var.location
  zone                     = var.availability_zone
  env                      = var.env
  subnet_id                = module.network.subnet_servers_id
  backend_address_pool_id  = length(module.lb) > 0 ? module.lb[0].backend_address_pool_id : null
  outbound_backend_pool_id = module.network.outbound_backend_pool_id
  ppg_id                   = module.network.ppg_id
  key_vault_id             = module.keyvault_certs.key_vault_id
  key_vault_name           = module.keyvault_certs.key_vault_name
  vm_size                  = var.server_vm_size
  admin_username           = var.admin_username
  ssh_public_key           = local.shared_ssh_public_key
  vnet_cidr                = one(module.network.vnet_address_space)
  tags                     = var.tags

  depends_on = [local_sensitive_file.shared_ssh_private_key]
}

# Scenarios s2 and c2: Linux VM (.NET, Java Netty, or Go)
module "vm_linux_app" {
  count                    = local.is_linux_vm_scenario ? 1 : 0
  source                   = "./modules/vm-linux-app"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = var.location
  zone                     = var.availability_zone
  env                      = var.env
  subnet_id                = module.network.subnet_servers_id
  backend_address_pool_id  = length(module.lb) > 0 ? module.lb[0].backend_address_pool_id : null
  outbound_backend_pool_id = module.network.outbound_backend_pool_id
  ppg_id                   = module.network.ppg_id
  key_vault_id             = module.keyvault_certs.key_vault_id
  key_vault_name           = module.keyvault_certs.key_vault_name
  vm_size                  = var.server_vm_size
  admin_username           = var.admin_username
  ssh_public_key           = local.shared_ssh_public_key
  tags                     = var.tags

  depends_on = [local_sensitive_file.shared_ssh_private_key]
}

# Dedicated load-generator client VMSS in the client subnet (Contract §7; omitted for c0-cluster-only)
resource "azurerm_linux_virtual_machine_scale_set" "client_vmss" {
  count                        = local.needs_client_vm ? 1 : 0
  name                         = "wtt-${var.env}-client-loadgen-vmss"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = var.location
  sku                          = var.client_vm_size
  instances                    = 1
  admin_username               = var.admin_username
  proximity_placement_group_id = module.network.ppg_id
  zones                        = [var.availability_zone]
  zone_balance                 = false
  upgrade_mode                 = "Manual"
  overprovision                = false
  custom_data                  = base64encode(local.client_cloud_init)
  tags                         = var.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = local.shared_ssh_public_key
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
    name                          = "wtt-${var.env}-client-loadgen-nic"
    primary                       = true
    enable_accelerated_networking = true

    ip_configuration {
      name                                   = "wtt-${var.env}-client-loadgen-ipconfig"
      primary                                = true
      subnet_id                              = module.network.subnet_clients_id
      load_balancer_backend_address_pool_ids = [module.network.outbound_backend_pool_id]
    }

    dynamic "ip_configuration" {
      for_each = range(1, var.client_source_ip_count)

      content {
        name      = "wtt-${var.env}-client-loadgen-ipconfig-${ip_configuration.value}"
        primary   = false
        subnet_id = module.network.subnet_clients_id
      }
    }
  }

  lifecycle {
    ignore_changes = [admin_username]
  }

  depends_on = [local_sensitive_file.shared_ssh_private_key]
}

resource "azurerm_role_assignment" "client_kv_secrets_user" {
  count                = local.needs_client_vm ? 1 : 0
  scope                = module.keyvault_certs.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine_scale_set.client_vmss[0].identity[0].principal_id
}
