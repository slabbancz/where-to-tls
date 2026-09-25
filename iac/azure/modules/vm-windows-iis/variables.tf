variable "resource_group_name" {
  type        = string
  description = "Resource group name"
}

variable "location" {
  type        = string
  description = "Azure region"
}

variable "env" {
  type        = string
  description = "Environment identifier"
  default     = "perf"
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID for the standalone VM subnet"
}

variable "backend_address_pool_id" {
  type        = string
  description = "Azure Load Balancer backend address pool ID"
}

variable "outbound_backend_pool_id" {
  type        = string
  description = "Backend pool ID for explicit outbound SNAT"
}

variable "ppg_id" {
  type        = string
  description = "Proximity Placement Group ID"
}

variable "key_vault_id" {
  type        = string
  description = "Key Vault ID for RBAC role assignment"
}

variable "key_vault_name" {
  type        = string
  description = "Key Vault name for fetching certificate secrets"
}

variable "vm_size" {
  type        = string
  description = "VM SKU (Contract: Standard_D4s_v7)"
  default     = "Standard_D4s_v7"
}

variable "admin_username" {
  type        = string
  description = "Admin username for Windows VM"
  default     = "wttuseradm"
}

variable "ssh_public_key" {
  type        = string
  description = "Shared OpenSSH public key for the Windows administrator"
}

variable "vnet_cidr" {
  type        = string
  description = "VNet CIDR permitted to connect to Windows OpenSSH"
}

variable "admin_password" {
  type        = string
  description = "Admin password for Windows VM. Generated if null."
  default     = null
  sensitive   = true
}

variable "zone" {
  type        = string
  description = "Availability zone for PPG co-location"
  default     = "1"
}

variable "tags" {
  type        = map(string)
  description = "Resource tags"
  default     = {}
}
