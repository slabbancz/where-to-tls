variable "resource_group_name" {
  type        = string
  description = "Azure resource group name"
}

variable "location" {
  type        = string
  description = "Azure region"
}

variable "env" {
  type        = string
  description = "Environment identifier (e.g. perf)"
  default     = "perf"
}

variable "key_vault_id" {
  type        = string
  description = "Azure Key Vault ID to store repository token credentials"
}

variable "tags" {
  type        = map(string)
  description = "Resource tags"
  default     = {}
}
