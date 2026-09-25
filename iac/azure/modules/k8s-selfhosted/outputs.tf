output "control_plane_vmss_id" {
  value       = azurerm_linux_virtual_machine_scale_set.cp.id
  description = "Kubernetes control plane VMSS ID"
}

output "control_plane_vmss_name" {
  value       = azurerm_linux_virtual_machine_scale_set.cp.name
  description = "Name of the control plane VMSS"
}

output "control_plane_principal_id" {
  value       = azurerm_linux_virtual_machine_scale_set.cp.identity[0].principal_id
  description = "Control plane Managed Identity principal ID"
}

output "worker_vmss_ids" {
  value       = { for k, v in azurerm_linux_virtual_machine_scale_set.workers : k => v.id }
  description = "Map of node pool name to VMSS resource ID"
}

output "worker_principal_ids" {
  value       = { for k, v in azurerm_linux_virtual_machine_scale_set.workers : k => v.identity[0].principal_id }
  description = "Map of node pool name to Managed Identity principal ID"
}

output "control_plane_public_ip" {
  value       = var.enable_public_api_access && length(azurerm_public_ip.cp_mgmt) > 0 ? azurerm_public_ip.cp_mgmt[0].ip_address : null
  description = "Public IP address allocated for Kubernetes control plane management access (Contract §7)"
}

output "kube_api_port" {
  value       = var.enable_public_api_access ? local.kube_api_port : null
  description = "Public TCP port 443 mapped through the management LB to kube-apiserver port 6443"
}

output "kubeconfig_path" {
  value       = var.enable_public_api_access && var.kubeconfig_output_path != null ? var.kubeconfig_output_path : null
  description = "Local filesystem path to cluster admin kubeconfig with public server endpoint"
}

output "kubeconfig" {
  value       = var.enable_public_api_access && var.kubeconfig_output_path != null ? data.azurerm_key_vault_secret.kubeconfig[0].value : null
  description = "Cluster admin kubeconfig with its server endpoint rewritten to the public LB NAT mapping"
  sensitive   = true
}

output "operator_cidr_in_use" {
  value       = var.enable_public_api_access ? local.operator_cidr : null
  description = "The resolved operator CIDR permitted inbound to Kubernetes API (Contract §7)"

  precondition {
    condition = !var.enable_public_api_access || (
      local.operator_cidr != "0.0.0.0/0" &&
      !startswith(local.operator_cidr, "0.0.0.0") &&
      local.operator_cidr_is_valid
    )
    error_message = "Operator source must be a bare IPv4 address or an IPv4 network no larger than /24 (/24 through /32). Resolved value: '${local.operator_cidr}'."
  }
}
