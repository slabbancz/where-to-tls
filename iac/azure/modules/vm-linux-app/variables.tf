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
  description = "Key Vault name for cloud-init secret retrieval"
}

variable "vm_size" {
  type        = string
  description = "VM SKU (Contract: Standard_D4s_v7)"
  default     = "Standard_D4s_v7"
}

variable "admin_username" {
  type        = string
  description = "Admin username for VM"
  default     = "wttuseradm"
}

variable "ssh_public_key" {
  type        = string
  description = "Shared SSH public key supplied by the root module"
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
