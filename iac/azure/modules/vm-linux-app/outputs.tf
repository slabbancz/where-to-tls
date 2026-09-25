output "vmss_id" {
  value       = azurerm_linux_virtual_machine_scale_set.vmss.id
  description = "Linux application VMSS ID"
}

output "vmss_name" {
  value       = azurerm_linux_virtual_machine_scale_set.vmss.name
  description = "Linux application VMSS name"
}

output "principal_id" {
  value       = azurerm_linux_virtual_machine_scale_set.vmss.identity[0].principal_id
  description = "Principal ID of VM Managed Identity"
}
