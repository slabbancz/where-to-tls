output "lb_id" {
  value       = azurerm_lb.lb.id
  description = "Load Balancer ID"
}

output "lb_name" {
  value       = azurerm_lb.lb.name
  description = "Load Balancer name"
}

output "frontend_ip_address" {
  value       = azurerm_lb.lb.frontend_ip_configuration[0].private_ip_address
  description = "Private frontend IP address dialled by clients (Contract §7)"
}

output "public_ip_address" {
  value       = var.enable_public_ip ? azurerm_public_ip.lb[0].ip_address : null
  description = "Public IP address if enabled"
}

output "backend_address_pool_id" {
  value       = azurerm_lb_backend_address_pool.backend.id
  description = "Backend address pool ID"
}
