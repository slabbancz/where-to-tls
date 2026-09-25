output "vnet_id" {
  value       = azurerm_virtual_network.vnet.id
  description = "Virtual Network ID"
}

output "vnet_name" {
  value       = azurerm_virtual_network.vnet.name
  description = "Virtual Network name"
}

output "vnet_address_space" {
  value       = azurerm_virtual_network.vnet.address_space
  description = "Address space of the Virtual Network"
}

output "ppg_id" {
  value       = azurerm_proximity_placement_group.ppg.id
  description = "Proximity Placement Group ID (Contract §7)"
}

output "outbound_backend_pool_id" {
  value       = azurerm_lb_backend_address_pool.outbound.id
  description = "Backend pool ID for explicit Standard Load Balancer outbound SNAT"
}

output "outbound_public_ip" {
  value       = azurerm_public_ip.outbound.ip_address
  description = "Public IP used only for outbound SNAT"
}

output "ppg_name" {
  value       = azurerm_proximity_placement_group.ppg.name
  description = "Proximity Placement Group name"
}

output "subnet_clients_id" {
  value       = azurerm_subnet.clients.id
  description = "ID of the benchmark client subnet"
}

output "subnet_client_jumpbox_id" {
  value       = azurerm_subnet.client_jumpbox.id
  description = "ID of the ACI-exclusive client jumpbox subnet"
}

output "subnet_servers_id" {
  value       = azurerm_subnet.servers.id
  description = "ID of the standalone VM subnet"
}

output "subnet_k8s_cp_id" {
  value       = azurerm_subnet.k8s_cp.id
  description = "ID of the Kubernetes control-plane subnet"
}

output "subnet_k8s_nodes_id" {
  value       = azurerm_subnet.k8s_nodes.id
  description = "ID of the Kubernetes worker-node subnet"
}

output "subnet_prefixes" {
  value       = var.subnet_prefixes
  description = "Configured subnet CIDRs"
}
