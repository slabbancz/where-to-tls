# lb.tf — Standard Load Balancer (Contract §7: Internal Azure Standard LB with private frontend IP for VM scenarios)
# Kubernetes scenarios (s4, s5, s6, c4) provision their own internal LoadBalancer via cloud-provider-azure (CCM).
# Keep the Terraform-managed VM LB persistent across scenario selection: the
# client cloud-init references it, and switching to a Kubernetes scenario must
# never try to remove a pool still attached to the standalone VMSS.
module "lb" {
  count               = 1
  source              = "./modules/lb"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  env                 = var.env
  subnet_id           = module.network.subnet_servers_id
  enable_public_ip    = var.enable_public_lb_ip
  backend_port_tls    = 8443
  backend_port_plain  = 8080
  probe_port          = 8080
  probe_path          = "/healthz"
  tags                = var.tags
}
