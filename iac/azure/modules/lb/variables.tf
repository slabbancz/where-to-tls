variable "resource_group_name" {
  type        = string
  description = "Name of the Azure resource group"
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

variable "subnet_id" {
  type        = string
  description = "Subnet ID for internal Load Balancer private frontend IP"
}

variable "private_ip_address" {
  type        = string
  description = "Optional static private IP for LB frontend. If empty, dynamic is used."
  default     = null
}

variable "enable_public_ip" {
  type        = bool
  description = "Optionally deploy a public IP for development/management. Contract §7 benchmark path is private."
  default     = false
}

variable "backend_port_tls" {
  type        = number
  description = "Backend port for TLS traffic (8443 for VMs, or NodePort 30443 for k8s)"
  default     = 8443
}

variable "backend_port_plain" {
  type        = number
  description = "Backend port for plaintext HTTP traffic (8080 for VMs, or NodePort 30080 for k8s)"
  default     = 8080
}

variable "probe_port" {
  type        = number
  description = "Port to hit for /healthz probe (8080 for VMs, or NodePort 30080 for k8s)"
  default     = 8080
}

variable "probe_path" {
  type        = string
  description = "Path for health probe. Must be /healthz per Contract §2."
  default     = "/healthz"
}

variable "tags" {
  type        = map(string)
  description = "Resource tags"
  default     = {}
}
