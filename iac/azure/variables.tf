variable "subscription_id" {
  type        = string
  description = "Azure Subscription ID"
}

variable "tenant_id" {
  type        = string
  description = "Azure Tenant ID"
  default     = null
}

variable "location" {
  type        = string
  description = "Azure region for deployment (Contract: northeurope)"
  default     = "westus2"
}

variable "env" {
  type        = string
  description = "Environment identifier (Contract §4: wtt-<env>-<scenario_id>-<resource>)"
  default     = "perf"
}

variable "availability_zone" {
  type        = string
  description = "Availability zone shared by all VMSS resources in the proximity placement group"
  default     = "3"

  validation {
    condition     = contains(["1", "2", "3"], var.availability_zone)
    error_message = "availability_zone must be 1, 2, or 3."
  }
}

variable "control_plane_vm_size" {
  type        = string
  description = "Control plane VM SKU (Contract §1a: Standard_B2s burstable)"
  default     = "Standard_B2s"
}

variable "server_vm_size" {
  type        = string
  description = "Server VM SKU (Contract §1a: Standard_D4s_v7 across all stacks)"
  default     = "Standard_D4s_v7"
}

variable "client_vm_size" {
  type        = string
  description = "Client load-generator VM SKU (Contract §7: Standard_D4s_v7)"
  default     = "Standard_D8s_v7"
}

variable "k8s_capacity_workload" {
  type        = number
  description = "Number of Kubernetes workload worker nodes to keep provisioned while benchmark scenarios change."
  default     = 1
}

variable "k8s_capacity_traefik" {
  type        = number
  description = "Number of Kubernetes Traefik worker nodes to keep provisioned while benchmark scenarios change."
  default     = 1
}

variable "client_source_ip_count" {
  type        = number
  description = "Number of private IPv4 source-address pools on the client VMSS primary NIC, including its primary address"
  default     = 4

  validation {
    condition     = var.client_source_ip_count >= 1 && var.client_source_ip_count <= 32 && floor(var.client_source_ip_count) == var.client_source_ip_count
    error_message = "client_source_ip_count must be an integer from 1 through 32."
  }
}

variable "active_scenario" {
  type        = string
  description = "The single active benchmark scenario to deploy (Contract §1 & §1a)"
  default     = "s2-vm-net"

  validation {
    condition = contains([
      "c0-cluster-only",
      "c0-vm-only",
      "s1-iis-netfx",
      "s2-vm-net",
      "s2-vm-java",
      "s2-vm-go",
      "s2-vm-rust",
      "s4-k8s-pod-net",
      "s4-k8s-pod-java",
      "s4-k8s-pod-go",
      "s4-k8s-pod-rust",
      "s5-traefik-passthrough-net",
      "s5-traefik-passthrough-java",
      "s5-traefik-passthrough-go",
      "s5-traefik-passthrough-rust",
      "s6-traefik-terminate-net",
      "s6-traefik-terminate-java",
      "s6-traefik-terminate-go",
      "s6-traefik-terminate-rust",
      "c2-vm-net-plain",
      "c2-vm-java-plain",
      "c2-vm-go-plain",
      "c2-vm-rust-plain",
      "c4-k8s-pod-net-plain",
      "c4-k8s-pod-java-plain",
      "c4-k8s-pod-go-plain",
      "c4-k8s-pod-rust-plain"
    ], var.active_scenario)
    error_message = "active_scenario must match one of the defined scenarios in docs/CONTRACT.md §1."
  }
}

variable "k8s_version" {
  type        = string
  description = "Kubernetes exact patch version for cluster components (Contract §4)"
  default     = "1.36.4"
}

variable "dns_zone" {
  type        = string
  description = "DNS zone for scenario hostnames (Contract §4: <scenario_id>.<zone>)"
  default     = "wtt.local"
}

variable "admin_username" {
  type        = string
  description = "Default admin username for provisioned VMs"
  default     = "wttuseradm"
}

variable "ssh_public_key" {
  type        = string
  description = "Optional SSH public key for VM access. Generated if omitted."
  default     = null
}

variable "k8s_ssh_enabled" {
  type        = bool
  description = "Install and configure OpenSSH on Kubernetes control-plane and worker nodes."
  default     = true
}

variable "client_jumpbox_enabled" {
  type        = bool
  description = "Create a private Azure Container Instances jumpbox in the client subnet for interactive diagnostics."
  default     = false
}

variable "client_jumpbox_image" {
  type        = string
  description = "Docker Hub library image and tag mirrored to wtt/<image> in ACR for the private diagnostics jumpbox."
  default     = "alpine:edge"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]*:[A-Za-z0-9][A-Za-z0-9._-]*$", var.client_jumpbox_image))
    error_message = "client_jumpbox_image must be an unqualified image and explicit tag, for example alpine:edge."
  }
}

variable "enable_public_lb_ip" {
  type        = bool
  description = "Attach public IP to LB for external debug access. Contract §7 benchmark path is private."
  default     = false
}

variable "operator_source_ip" {
  type        = string
  description = "Optional override for operator public CIDR permitted inbound to Kubernetes API (Contract §7, e.g. 203.0.113.4/32). When null, auto-detected via api.ipify.org at apply time (use when VPN or apply network differs from kubectl workstation)."
  default     = null

  validation {
    condition = var.operator_source_ip == null || (
      var.operator_source_ip != "0.0.0.0/0" &&
      !startswith(var.operator_source_ip, "0.0.0.0") &&
      (
        can(cidrnetmask(var.operator_source_ip)) ?
        (tonumber(split("/", var.operator_source_ip)[1]) >= 24 && tonumber(split("/", var.operator_source_ip)[1]) <= 32) :
        can(cidrnetmask("${var.operator_source_ip}/32"))
      )
    )
    error_message = "operator_source_ip must be null, a bare IPv4 address, or an IPv4 network no larger than /24 (/24 through /32)."
  }
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags"
  default = {
    Project   = "where-to-tls"
    ManagedBy = "opentofu"
    Purpose   = "benchmark"
  }
}
