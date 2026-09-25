data "http" "operator_ip" {
  count = var.operator_source_ip == null ? 1 : 0
  url   = "https://api.ipify.org"

  lifecycle {
    postcondition {
      condition     = can(cidrnetmask("${chomp(self.response_body)}/32"))
      error_message = "Auto-detected operator IP from api.ipify.org is not a valid bare IPv4 address: '${chomp(self.response_body)}'."
    }
  }
}

locals {
  k8s_repo_version = "v${join(".", slice(split(".", var.kubernetes_version), 0, 2))}"
  kube_api_port    = 443

  operator_cidr                = var.operator_source_ip != null ? var.operator_source_ip : "${chomp(data.http.operator_ip[0].response_body)}/32"
  operator_cidr_for_validation = can(cidrnetmask(local.operator_cidr)) ? local.operator_cidr : "${local.operator_cidr}/32"
  operator_cidr_is_valid = can(cidrnetmask(local.operator_cidr_for_validation)) && (
    tonumber(split("/", local.operator_cidr_for_validation)[1]) >= 24 &&
    tonumber(split("/", local.operator_cidr_for_validation)[1]) <= 32
  )

  cp_pip_name    = var.cp_mgmt_public_ip_name != null ? var.cp_mgmt_public_ip_name : "${var.cluster_name}-cp-mgmt-pip"
  cp_lb_name     = var.cp_mgmt_lb_name != null ? var.cp_mgmt_lb_name : "${var.cluster_name}-cp-mgmt-lb"
  cp_nsg_name    = var.cp_mgmt_nsg_name != null ? var.cp_mgmt_nsg_name : "${var.cluster_name}-cp-mgmt-nsg"
  nodes_nsg_name = "${var.cluster_name}-nodes-nsg"

  cp_cloud_init = templatefile("${path.module}/../../../bootstrap/cloud-init/k8s-control-plane.yaml.tftpl", {
    admin_username                     = var.admin_username
    ssh_enabled                        = var.ssh_enabled
    key_vault_name                     = var.key_vault_name
    pod_cidr                           = var.pod_cidr
    k8s_version                        = var.kubernetes_version
    k8s_repo_version                   = local.k8s_repo_version
    subscription_id                    = var.subscription_id
    tenant_id                          = var.tenant_id
    resource_group_name                = var.resource_group_name
    location                           = var.location
    vnet_name                          = var.vnet_name
    subnet_nodes_name                  = var.subnet_nodes_name
    security_group_name                = local.nodes_nsg_name
    zone                               = var.zone
    cp_public_ip                       = var.enable_public_api_access && length(azurerm_public_ip.cp_mgmt) > 0 ? azurerm_public_ip.cp_mgmt[0].ip_address : ""
    cp_nat_port                        = var.enable_public_api_access ? local.kube_api_port : 0
    post_bootstrap_script              = var.post_bootstrap_script
    configure_os_script                = file("${path.module}/../../../bootstrap/k8s/configure-os.sh")
    configure_ssh_script               = file("${path.module}/../../../bootstrap/node/configure-linux-ssh.sh")
    install_containerd_script          = file("${path.module}/../../../bootstrap/k8s/install-containerd.sh")
    install_kubernetes_script          = file("${path.module}/../../../bootstrap/k8s/install-kubernetes.sh")
    init_control_plane_script          = file("${path.module}/../../../bootstrap/k8s/init-control-plane.sh")
    mount_control_plane_state_script   = file("${path.module}/../../../bootstrap/k8s/mount-control-plane-state.sh")
    get_identity_token_script          = file("${path.module}/../../../bootstrap/cloud/azure/get-identity-token.sh")
    get_provider_id_script             = file("${path.module}/../../../bootstrap/cloud/azure/get-provider-id.sh")
    get_secret_script                  = file("${path.module}/../../../bootstrap/cloud/azure/get-secret.sh")
    publish_secret_script              = file("${path.module}/../../../bootstrap/cloud/azure/publish-secret.sh")
    write_cloud_provider_config_script = file("${path.module}/../../../bootstrap/cloud/azure/configure-cloud-provider.sh")
  })

  worker_cloud_init = {
    for pool_name, pool in var.node_pools : pool_name => templatefile("${path.module}/../../../bootstrap/cloud-init/k8s-worker.yaml.tftpl", {
      key_vault_name                     = var.key_vault_name
      admin_username                     = var.admin_username
      ssh_enabled                        = var.ssh_enabled
      pool_name                          = pool_name
      labels_str                         = join(",", [for k, v in pool.labels : "${k}=${v}"])
      taints_str                         = length(pool.taints) > 0 ? "--register-with-taints=${join(",", pool.taints)}" : ""
      k8s_version                        = var.kubernetes_version
      k8s_repo_version                   = local.k8s_repo_version
      subscription_id                    = var.subscription_id
      tenant_id                          = var.tenant_id
      resource_group_name                = var.resource_group_name
      location                           = var.location
      vnet_name                          = var.vnet_name
      subnet_nodes_name                  = var.subnet_nodes_name
      security_group_name                = local.nodes_nsg_name
      zone                               = var.zone
      configure_os_script                = file("${path.module}/../../../bootstrap/k8s/configure-os.sh")
      configure_ssh_script               = file("${path.module}/../../../bootstrap/node/configure-linux-ssh.sh")
      install_containerd_script          = file("${path.module}/../../../bootstrap/k8s/install-containerd.sh")
      install_kubernetes_script          = file("${path.module}/../../../bootstrap/k8s/install-kubernetes.sh")
      join_worker_script                 = file("${path.module}/../../../bootstrap/k8s/join-worker.sh")
      get_identity_token_script          = file("${path.module}/../../../bootstrap/cloud/azure/get-identity-token.sh")
      get_provider_id_script             = file("${path.module}/../../../bootstrap/cloud/azure/get-provider-id.sh")
      get_secret_script                  = file("${path.module}/../../../bootstrap/cloud/azure/get-secret.sh")
      write_cloud_provider_config_script = file("${path.module}/../../../bootstrap/cloud/azure/configure-cloud-provider.sh")
    })
  }
}

# ------------------------------------------------------------------------------
# Kubernetes Control Plane VMSS (Fixed at capacity 1, Standard_B2s burstable)
# Apply VMSS model upgrades explicitly to avoid unplanned node disruption.
# ------------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine_scale_set" "cp" {
  name                         = "${var.cluster_name}-cp-vmss"
  resource_group_name          = var.resource_group_name
  location                     = var.location
  sku                          = var.control_plane_size
  instances                    = 1
  admin_username               = var.admin_username
  proximity_placement_group_id = var.ppg_id
  zone_balance                 = false
  zones                        = [var.zone]
  custom_data                  = base64encode(local.cp_cloud_init)
  tags                         = merge(var.tags, { "wtt_pool" = "cp" })
  upgrade_mode                 = "Manual"
  overprovision                = false

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  data_disk {
    lun                  = 0
    caching              = "None"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 2
    create_option        = "Empty"
  }

  boot_diagnostics {}

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-26_04-lts"
    sku       = "server"
    version   = "latest"
  }

  network_interface {
    name                          = "${var.cluster_name}-cp-nic"
    primary                       = true
    enable_accelerated_networking = false
    network_security_group_id     = var.enable_public_api_access && length(azurerm_network_security_group.cp_mgmt) > 0 ? azurerm_network_security_group.cp_mgmt[0].id : null

    ip_configuration {
      name                                = "${var.cluster_name}-cp-ipconfig"
      primary                             = true
      subnet_id                           = var.subnet_cp_id
      load_balancer_inbound_nat_rules_ids = var.enable_public_api_access && length(azurerm_lb_nat_pool.cp_kube_api) > 0 ? [azurerm_lb_nat_pool.cp_kube_api[0].id] : []
      load_balancer_backend_address_pool_ids = concat(
        [var.outbound_backend_pool_id],
        var.enable_public_api_access && length(azurerm_lb_backend_address_pool.cp_mgmt) > 0 ? [azurerm_lb_backend_address_pool.cp_mgmt[0].id] : []
      )
    }
  }

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    ignore_changes = [admin_username]
  }
}

# Control plane VMSS writes join token into Key Vault
resource "azurerm_role_assignment" "cp_kv_officer" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_linux_virtual_machine_scale_set.cp.identity[0].principal_id
}

# Control plane VMSS needs Network Contributor on RG for cloud-provider-azure (CCM)
resource "azurerm_role_assignment" "cp_network_contributor" {
  scope                = var.resource_group_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_linux_virtual_machine_scale_set.cp.identity[0].principal_id
}

resource "azurerm_role_assignment" "cp_reader" {
  scope                = var.resource_group_id
  role_definition_name = "Reader"
  principal_id         = azurerm_linux_virtual_machine_scale_set.cp.identity[0].principal_id
}

resource "azurerm_network_security_group" "nodes" {
  name                = local.nodes_nsg_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# ------------------------------------------------------------------------------
# Generic Worker Node Pools (VMSS per entry in var.node_pools)
# ------------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine_scale_set" "workers" {
  for_each = var.node_pools

  name                         = "${var.cluster_name}-${each.key}-vmss"
  resource_group_name          = var.resource_group_name
  location                     = var.location
  sku                          = each.value.size
  instances                    = each.value.capacity
  admin_username               = var.admin_username
  proximity_placement_group_id = var.ppg_id
  zone_balance                 = false
  zones                        = [var.zone]
  custom_data                  = base64encode(local.worker_cloud_init[each.key])
  tags                         = merge(var.tags, { "wtt_pool" = each.key })
  upgrade_mode                 = "Manual"
  overprovision                = false

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

  network_interface {
    name                          = "${var.cluster_name}-${each.key}-nic"
    primary                       = true
    enable_accelerated_networking = true
    network_security_group_id     = azurerm_network_security_group.nodes.id

    ip_configuration {
      name                                   = "${var.cluster_name}-${each.key}-ipconfig"
      primary                                = true
      subnet_id                              = var.subnet_nodes_id
      load_balancer_backend_address_pool_ids = [var.outbound_backend_pool_id]
    }
  }

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    ignore_changes = [admin_username]
  }

  depends_on = [azurerm_linux_virtual_machine_scale_set.cp]
}

resource "azurerm_role_assignment" "workers_kv_user" {
  for_each = var.node_pools

  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine_scale_set.workers[each.key].identity[0].principal_id
}

resource "azurerm_role_assignment" "workers_network_contributor" {
  for_each = var.node_pools

  scope                = var.resource_group_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_linux_virtual_machine_scale_set.workers[each.key].identity[0].principal_id
}

# ------------------------------------------------------------------------------
# Control Plane External Management Access (Contract §7)
# Separate Public Load Balancer with TCP 443 mapped to 6443,
# restricted to operator_source_ip via single allow NSG rule on CP NIC.
# ------------------------------------------------------------------------------
resource "azurerm_public_ip" "cp_mgmt" {
  count               = var.enable_public_api_access ? 1 : 0
  name                = local.cp_pip_name
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_lb" "cp_mgmt" {
  count               = var.enable_public_api_access ? 1 : 0
  name                = local.cp_lb_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                 = "${var.cluster_name}-cp-mgmt-frontend"
    public_ip_address_id = azurerm_public_ip.cp_mgmt[0].id
  }
}

resource "azurerm_lb_backend_address_pool" "cp_mgmt" {
  count           = var.enable_public_api_access ? 1 : 0
  name            = "${var.cluster_name}-cp-mgmt-backend-pool"
  loadbalancer_id = azurerm_lb.cp_mgmt[0].id
}

resource "azurerm_lb_nat_pool" "cp_kube_api" {
  count                          = var.enable_public_api_access ? 1 : 0
  name                           = "${var.cluster_name}-cp-api-nat"
  resource_group_name            = var.resource_group_name
  loadbalancer_id                = azurerm_lb.cp_mgmt[0].id
  frontend_ip_configuration_name = "${var.cluster_name}-cp-mgmt-frontend"
  protocol                       = "Tcp"
  frontend_port_start            = local.kube_api_port
  frontend_port_end              = local.kube_api_port + 9
  backend_port                   = 6443
}

resource "azurerm_network_security_group" "cp_mgmt" {
  count               = var.enable_public_api_access ? 1 : 0
  name                = local.cp_nsg_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  security_rule {
    name              = "${var.cluster_name}-allow-operator-kube-api"
    priority          = 100
    direction         = "Inbound"
    access            = "Allow"
    protocol          = "Tcp"
    source_port_range = "*"
    # Azure evaluates the NSG after the load balancer translates the NAT port.
    destination_port_ranges    = ["6443"]
    source_address_prefix      = local.operator_cidr
    destination_address_prefix = "*"
  }

  lifecycle {
    precondition {
      condition = (
        local.operator_cidr != "0.0.0.0/0" &&
        !startswith(local.operator_cidr, "0.0.0.0") &&
        local.operator_cidr_is_valid
      )
      error_message = "Operator source must be a bare IPv4 address or an IPv4 network no larger than /24 (/24 through /32). Resolved value: '${local.operator_cidr}'."
    }
  }
}

resource "terraform_data" "wait_for_kubeconfig" {
  count = var.enable_public_api_access && var.kubeconfig_output_path != null ? 1 : 0

  triggers_replace = [
    azurerm_linux_virtual_machine_scale_set.cp.id,
    var.key_vault_name,
    "k8s-kubeconfig",
  ]

  provisioner "local-exec" {
    command = "${path.root}/../bootstrap/local/wait-for-secret.sh '${var.key_vault_name}' k8s-kubeconfig 300 \"$(az vmss show --resource-group '${var.resource_group_name}' --name '${azurerm_linux_virtual_machine_scale_set.cp.name}' --query timeCreated --output tsv)\""
  }
}

data "azurerm_key_vault_secret" "kubeconfig" {
  count        = var.enable_public_api_access && var.kubeconfig_output_path != null ? 1 : 0
  name         = "k8s-kubeconfig"
  key_vault_id = var.key_vault_id

  depends_on = [terraform_data.wait_for_kubeconfig]
}

resource "local_file" "kubeconfig" {
  count           = var.enable_public_api_access && var.kubeconfig_output_path != null ? 1 : 0
  filename        = var.kubeconfig_output_path
  file_permission = "0600"
  content         = data.azurerm_key_vault_secret.kubeconfig[0].value
}
