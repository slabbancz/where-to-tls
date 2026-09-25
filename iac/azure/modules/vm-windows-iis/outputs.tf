output "vmss_id" {
  value       = azurerm_windows_virtual_machine_scale_set.vmss.id
  description = "Windows IIS VMSS ID"
}

output "vmss_name" {
  value       = azurerm_windows_virtual_machine_scale_set.vmss.name
  description = "Windows IIS VMSS name"
}

output "admin_password" {
  value       = local.admin_pass
  description = "Windows VM admin password"
  sensitive   = true
}
