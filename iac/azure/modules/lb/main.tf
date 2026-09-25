# Azure Standard Load Balancer (L4 only, no TLS termination at LB)
resource "azurerm_public_ip" "lb" {
  count               = var.enable_public_ip ? 1 : 0
  name                = "wtt-${var.env}-vm-lb-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_lb" "lb" {
  name                = "wtt-${var.env}-vm-lb"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  tags                = var.tags

  # Contract §7: Internal Azure Standard LB with private frontend IP
  frontend_ip_configuration {
    name                          = "wtt-${var.env}-vm-private-frontend"
    subnet_id                     = var.subnet_id
    private_ip_address            = var.private_ip_address
    private_ip_address_allocation = var.private_ip_address != null ? "Static" : "Dynamic"
  }

  dynamic "frontend_ip_configuration" {
    for_each = var.enable_public_ip ? [1] : []
    content {
      name                 = "wtt-${var.env}-vm-public-frontend"
      public_ip_address_id = azurerm_public_ip.lb[0].id
    }
  }
}

resource "azurerm_lb_backend_address_pool" "backend" {
  name            = "wtt-${var.env}-vm-backend-pool"
  loadbalancer_id = azurerm_lb.lb.id
}

# Contract §2: Health probes must hit /healthz and must never hit a benchmarked endpoint
resource "azurerm_lb_probe" "healthz" {
  name                = "wtt-${var.env}-vm-healthz-probe"
  loadbalancer_id     = azurerm_lb.lb.id
  protocol            = "Http"
  port                = var.probe_port
  request_path        = var.probe_path
  interval_in_seconds = 5
  number_of_probes    = 2
}

# LB rule for TLS (8443)
resource "azurerm_lb_rule" "tls" {
  name                           = "wtt-${var.env}-vm-tls-rule"
  loadbalancer_id                = azurerm_lb.lb.id
  protocol                       = "Tcp"
  frontend_port                  = 8443
  backend_port                   = var.backend_port_tls
  frontend_ip_configuration_name = "wtt-${var.env}-vm-private-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.backend.id]
  probe_id                       = azurerm_lb_probe.healthz.id
  idle_timeout_in_minutes        = 30
  floating_ip_enabled            = false
}

# LB rule for Plaintext HTTP (8080)
resource "azurerm_lb_rule" "plain" {
  name                           = "wtt-${var.env}-vm-http-rule"
  loadbalancer_id                = azurerm_lb.lb.id
  protocol                       = "Tcp"
  frontend_port                  = 8080
  backend_port                   = var.backend_port_plain
  frontend_ip_configuration_name = "wtt-${var.env}-vm-private-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.backend.id]
  probe_id                       = azurerm_lb_probe.healthz.id
  idle_timeout_in_minutes        = 30
  floating_ip_enabled            = false
}
