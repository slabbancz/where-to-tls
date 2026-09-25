variable "cluster_name" {
  type        = string
  description = "Cluster identifier used in resource naming"
  default     = "k8s"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group name"
}

variable "resource_group_id" {
  type        = string
  description = "Resource group resource ID for Network Contributor role assignment"
}

variable "location" {
  type        = string
  description = "Azure region"
}

variable "subscription_id" {
  type        = string
  description = "Azure Subscription ID for azure.json"
}

variable "tenant_id" {
  type        = string
  description = "Azure Tenant ID for azure.json"
  default     = ""
}

variable "vnet_name" {
  type        = string
  description = "Virtual network name for azure.json"
}

variable "subnet_nodes_name" {
  type        = string
  description = "Subnet name for worker nodes in azure.json"
  default     = "wtt-perf-k8s-nodes-snet"
}

variable "subnet_cp_id" {
  type        = string
  description = "Subnet ID for control plane VMSS"
}

variable "subnet_nodes_id" {
  type        = string
  description = "Subnet ID for worker node pools VMSS"
}

variable "outbound_backend_pool_id" {
  type        = string
  description = "Backend pool ID for explicit outbound SNAT"
}

variable "ppg_id" {
  type        = string
  description = "Proximity Placement Group ID (optional)"
  default     = null
}

variable "key_vault_id" {
  type        = string
  description = "Key Vault ID for RBAC role assignments"
}

variable "key_vault_name" {
  type        = string
  description = "Key Vault name where CP writes join token and workers read it"
}

variable "control_plane_size" {
  type        = string
  description = "VM SKU for control plane (Contract §1a: Standard_B2s burstable)"
  default     = "Standard_B2s"
}

variable "node_pools" {
  type = map(object({
    size     = string
    capacity = number
    labels   = optional(map(string), {})
    taints   = optional(list(string), [])
  }))
  description = "Map of worker node pool configurations (pool name -> size, capacity, labels, taints)"
  default     = {}
}

variable "admin_username" {
  type        = string
  description = "Admin username for cluster VMs"
  default     = "wttuseradm"
}

variable "ssh_public_key" {
  type        = string
  description = "Shared SSH public key supplied by the root module"
}

variable "ssh_enabled" {
  type        = bool
  description = "Install and configure OpenSSH on Kubernetes nodes"
  default     = true
}

variable "zone" {
  type        = string
  description = "Availability zone for cluster placement"
  default     = "1"
}

variable "pod_cidr" {
  type        = string
  description = "Pod network CIDR"
  default     = "10.244.0.0/16"
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes exact patch version for cluster components"
  default     = "1.36.4"
}

variable "post_bootstrap_script" {
  type        = string
  description = "Optional benchmark-specific script executed on the control-plane node after kubeadm initialization"
  default     = ""
}

variable "operator_source_ip" {
  type        = string
  description = "Optional override for operator public CIDR permitted inbound to Kubernetes API (Contract §7, e.g. 203.0.113.4/32). When null, auto-detected via api.ipify.org at apply time."
  default     = null
}

variable "enable_public_api_access" {
  type        = bool
  description = "Provision public IP, Load Balancer NAT pool, and NSG for external kube-apiserver management access (Contract §7)"
  default     = true
}

variable "kubeconfig_output_path" {
  type        = string
  description = "Local filesystem path to emit cluster admin kubeconfig. If null, local_file is skipped."
  default     = null
}

variable "cp_mgmt_public_ip_name" {
  type        = string
  description = "Resource name override for control plane public IP"
  default     = null
}

variable "cp_mgmt_lb_name" {
  type        = string
  description = "Resource name override for control plane management load balancer"
  default     = null
}

variable "cp_mgmt_nsg_name" {
  type        = string
  description = "Resource name override for control plane management NSG"
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Resource tags"
  default     = {}
}
