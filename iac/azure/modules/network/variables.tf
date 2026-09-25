variable "resource_group_name" {
  type        = string
  description = "Name of the Azure resource group"
}

variable "location" {
  type        = string
  description = "Azure region (e.g. northeurope)"
}

variable "env" {
  type        = string
  description = "Environment identifier (e.g. perf)"
  default     = "perf"
}

variable "vnet_address_space" {
  type        = list(string)
  description = "Address space for the virtual network"
  default     = ["10.0.0.0/16"]
}

variable "subnet_prefixes" {
  type = object({
    clients        = string
    client_jumpbox = string
    servers        = string
    k8s_cp         = string
    k8s_nodes      = string
  })
  description = "CIDR prefixes for the contract subnets"
  default = {
    clients        = "10.0.1.0/24"
    client_jumpbox = "10.0.8.0/28"
    servers        = "10.0.2.0/24"
    k8s_cp         = "10.0.3.0/24"
    k8s_nodes      = "10.0.4.0/22"
  }
}

variable "tags" {
  type        = map(string)
  description = "Resource tags"
  default     = {}
}
