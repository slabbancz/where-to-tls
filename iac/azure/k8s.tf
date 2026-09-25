# k8s.tf — Self-hosted Kubernetes cluster (Control Plane VMSS + Worker VMSS pools, Contract §1a & §4)
# The cluster module is standalone and generic; benchmark-specific post-bootstrap provisioning is supplied here.

locals {
  benchmark_post_bootstrap_script = file("${path.root}/../bootstrap/k8s/materialize-workload-secrets.sh")
}

module "k8s_selfhosted" {
  count                    = local.cluster_enabled ? 1 : 0
  source                   = "./modules/k8s-selfhosted"
  cluster_name             = "wtt-${var.env}-k8s"
  resource_group_name      = azurerm_resource_group.rg.name
  resource_group_id        = azurerm_resource_group.rg.id
  location                 = var.location
  zone                     = var.availability_zone
  subscription_id          = var.subscription_id
  tenant_id                = var.tenant_id != null ? var.tenant_id : ""
  vnet_name                = module.network.vnet_name
  subnet_nodes_name        = "wtt-${var.env}-k8s-nodes-snet"
  subnet_cp_id             = module.network.subnet_k8s_cp_id
  subnet_nodes_id          = module.network.subnet_k8s_nodes_id
  outbound_backend_pool_id = module.network.outbound_backend_pool_id
  ppg_id                   = module.network.ppg_id
  key_vault_id             = module.keyvault_certs.key_vault_id
  key_vault_name           = module.keyvault_certs.key_vault_name
  control_plane_size       = var.control_plane_vm_size
  admin_username           = var.admin_username
  ssh_public_key           = local.shared_ssh_public_key
  ssh_enabled              = var.k8s_ssh_enabled
  kubernetes_version       = var.k8s_version
  post_bootstrap_script    = local.benchmark_post_bootstrap_script
  operator_source_ip       = var.operator_source_ip
  enable_public_api_access = true
  kubeconfig_output_path   = "${path.root}/../../results/kubeconfig"
  cp_mgmt_public_ip_name   = "wtt-${var.env}-k8s-cp-mgmt-pip"
  cp_mgmt_lb_name          = "wtt-${var.env}-k8s-cp-mgmt-lb"
  cp_mgmt_nsg_name         = "wtt-${var.env}-k8s-cp-mgmt-nsg"

  node_pools = {
    workload = {
      size     = var.server_vm_size
      capacity = local.k8s_capacity_workload
      labels = {
        "wtt/pool" = "workload"
      }
    }
    traefik = {
      size     = var.server_vm_size
      capacity = local.k8s_capacity_traefik
      labels = {
        "wtt/pool" = "traefik"
      }
    }
  }

  tags = var.tags

  depends_on = [local_sensitive_file.shared_ssh_private_key]
}