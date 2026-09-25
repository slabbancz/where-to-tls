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

variable "dns_zone" {
  type        = string
  description = "DNS zone name for SANs (e.g. wtt.local)"
  default     = "wtt.local"
}

variable "ssh_public_key" {
  type        = string
  description = "Shared OpenSSH public key stored in Key Vault for host bootstrap"
}

variable "ssh_private_key" {
  type        = string
  description = "Shared SSH private key for the private jumpbox; null when an external key is supplied"
  default     = null
  sensitive   = true
}

variable "store_ssh_private_key" {
  type        = bool
  description = "Whether this run generated a shared SSH private key that must be available to the private jumpbox."
}

variable "tls_dns_names" {
  type        = list(string)
  description = "DNS names covered by the shared benchmark leaf certificate"
  default = [
    "c0-vm-only.wtt.local",
    "s1-iis-netfx.wtt.local",
    "s2-vm-net.wtt.local",
    "s2-vm-java.wtt.local",
    "s2-vm-go.wtt.local",
    "s2-vm-rust.wtt.local",
    "s4-k8s-pod-net.wtt.local",
    "s4-k8s-pod-java.wtt.local",
    "s4-k8s-pod-go.wtt.local",
    "s4-k8s-pod-rust.wtt.local",
    "s5-traefik-passthrough-net.wtt.local",
    "s5-traefik-passthrough-java.wtt.local",
    "s5-traefik-passthrough-go.wtt.local",
    "s5-traefik-passthrough-rust.wtt.local",
    "s6-traefik-terminate-net.wtt.local",
    "s6-traefik-terminate-java.wtt.local",
    "s6-traefik-terminate-go.wtt.local",
    "s6-traefik-terminate-rust.wtt.local"
  ]

  validation {
    condition     = length(var.tls_dns_names) > 0
    error_message = "tls_dns_names must contain at least one hostname."
  }
}

variable "tags" {
  type        = map(string)
  description = "Resource tags"
  default     = {}
}
