# outputs.tf — Documented boundary consumed by the benchmark harness.
# Must emit at minimum:
# - Map keyed by scenario_id giving dialable hostname/IP per scenario
# - ca_pem
# - key_vault_name

locals {
  terraform_lb_ip = length(module.lb) > 0 ? module.lb[0].frontend_ip_address : null

  all_scenarios = {
    "s1-iis-netfx" = {
      stack             = "netfx48"
      tls_terminated_at = "iis"
      is_tls            = true
    }
    "s2-vm-net" = {
      stack             = "net10"
      tls_terminated_at = "vm"
      is_tls            = true
    }
    "s2-vm-java" = {
      stack             = "java-netty"
      tls_terminated_at = "vm"
      is_tls            = true
    }
    "s2-vm-go" = {
      stack             = "go"
      tls_terminated_at = "vm"
      is_tls            = true
    }
    "s2-vm-rust" = {
      stack             = "rust"
      tls_terminated_at = "vm"
      is_tls            = true
    }
    "s4-k8s-pod-net" = {
      stack             = "net10"
      tls_terminated_at = "pod"
      is_tls            = true
    }
    "s4-k8s-pod-java" = {
      stack             = "java-netty"
      tls_terminated_at = "pod"
      is_tls            = true
    }
    "s4-k8s-pod-go" = {
      stack             = "go"
      tls_terminated_at = "pod"
      is_tls            = true
    }
    "s4-k8s-pod-rust" = {
      stack             = "rust"
      tls_terminated_at = "pod"
      is_tls            = true
    }
    "s5-traefik-passthrough-net" = {
      stack             = "net10"
      tls_terminated_at = "pod"
      is_tls            = true
    }
    "s5-traefik-passthrough-java" = {
      stack             = "java-netty"
      tls_terminated_at = "pod"
      is_tls            = true
    }
    "s5-traefik-passthrough-go" = {
      stack             = "go"
      tls_terminated_at = "pod"
      is_tls            = true
    }
    "s5-traefik-passthrough-rust" = {
      stack             = "rust"
      tls_terminated_at = "pod"
      is_tls            = true
    }
    "s6-traefik-terminate-net" = {
      stack             = "net10"
      tls_terminated_at = "traefik"
      is_tls            = true
    }
    "s6-traefik-terminate-java" = {
      stack             = "java-netty"
      tls_terminated_at = "traefik"
      is_tls            = true
    }
    "s6-traefik-terminate-go" = {
      stack             = "go"
      tls_terminated_at = "traefik"
      is_tls            = true
    }
    "s6-traefik-terminate-rust" = {
      stack             = "rust"
      tls_terminated_at = "traefik"
      is_tls            = true
    }
    "c2-vm-net-plain" = {
      stack             = "net10"
      tls_terminated_at = "none"
      is_tls            = false
    }
    "c2-vm-java-plain" = {
      stack             = "java-netty"
      tls_terminated_at = "none"
      is_tls            = false
    }
    "c2-vm-go-plain" = {
      stack             = "go"
      tls_terminated_at = "none"
      is_tls            = false
    }
    "c2-vm-rust-plain" = {
      stack             = "rust"
      tls_terminated_at = "none"
      is_tls            = false
    }
    "c4-k8s-pod-net-plain" = {
      stack             = "net10"
      tls_terminated_at = "none"
      is_tls            = false
    }
    "c4-k8s-pod-java-plain" = {
      stack             = "java-netty"
      tls_terminated_at = "none"
      is_tls            = false
    }
    "c4-k8s-pod-go-plain" = {
      stack             = "go"
      tls_terminated_at = "none"
      is_tls            = false
    }
    "c4-k8s-pod-rust-plain" = {
      stack             = "rust"
      tls_terminated_at = "none"
      is_tls            = false
    }
    "c0-cluster-only" = {
      stack             = "go"
      tls_terminated_at = "none"
      is_tls            = false
    }
    "c0-vm-only" = {
      stack             = "go"
      tls_terminated_at = "vm"
      is_tls            = true
    }
  }
}

output "scenarios" {
  description = "Map keyed by scenario_id giving dialable hostname, IP, and metadata per scenario (Contract §1 & §4)"
  value = {
    for id, meta in local.all_scenarios : id => {
      scenario_id       = id
      hostname          = "${id}.${var.dns_zone}"
      ip                = local.terraform_lb_ip
      port_tls          = 8443
      port_plain        = 8080
      active_port       = meta.is_tls ? 8443 : 8080
      stack             = meta.stack
      tls_terminated_at = meta.tls_terminated_at
      is_active         = id == var.active_scenario
    }
  }
}

output "active_scenario" {
  description = "The active scenario deployed in this environment run"
  value       = var.active_scenario
}

output "active_endpoint" {
  description = "Connection details for the active scenario under test"
  value = {
    scenario_id = var.active_scenario
    hostname    = "${var.active_scenario}.${var.dns_zone}"
    ip          = local.terraform_lb_ip
    port_tls    = 8443
    port_plain  = 8080
  }
}

output "ca_pem" {
  description = "Run CA root certificate PEM (Contract §3: harness trusts this for TLS validation)"
  value       = module.keyvault_certs.ca_pem
}

output "key_vault_name" {
  description = "Azure Key Vault name hosting scenario certificates"
  value       = module.keyvault_certs.key_vault_name
}

output "key_vault_id" {
  description = "Azure Key Vault resource ID"
  value       = module.keyvault_certs.key_vault_id
}

output "resource_group_name" {
  description = "Azure Resource Group name"
  value       = azurerm_resource_group.rg.name
}

output "vnet_id" {
  description = "Virtual Network ID"
  value       = module.network.vnet_id
}

output "ssh_private_key_path" {
  description = "Local private-key path when OpenTofu generates the shared SSH key; null when ssh_public_key is supplied"
  value       = var.ssh_public_key == null ? abspath(local_sensitive_file.shared_ssh_private_key[0].filename) : null
}

output "load_balancer_ip" {
  description = "Private IP address of Azure Standard Load Balancer frontend (VM scenarios; k8s scenarios provisioned by CCM)"
  value       = local.terraform_lb_ip
}

output "client_vmss_name" {
  description = "Benchmark client VMSS name; null for scenarios without a client"
  value       = length(azurerm_linux_virtual_machine_scale_set.client_vmss) > 0 ? azurerm_linux_virtual_machine_scale_set.client_vmss[0].name : null
}

output "client_source_ip_count" {
  description = "Number of private source IPv4 addresses configured on the benchmark client primary NIC"
  value       = local.needs_client_vm ? var.client_source_ip_count : 0
}

output "dns_zone" {
  description = "Private benchmark DNS suffix used for scenario hostnames"
  value       = var.dns_zone
}

output "client_jumpbox_name" {
  description = "Private ACI jumpbox name when client_jumpbox_enabled is true"
  value       = length(azurerm_container_group.client_jumpbox) > 0 ? azurerm_container_group.client_jumpbox[0].name : null
}

# Azure Container Registry (Contract §4)
output "acr_login_server" {
  description = "Azure Container Registry login server (push target for code agent)"
  value       = module.acr.login_server
}

output "acr_registry_name" {
  description = "Azure Container Registry name"
  value       = module.acr.registry_name
}

output "linux_app_vmss_name" {
  description = "Standalone Linux application VMSS name for the active Linux VM scenario"
  value       = length(module.vm_linux_app) > 0 ? module.vm_linux_app[0].vmss_name : null
}

output "windows_iis_vmss_name" {
  description = "Standalone Windows IIS VMSS name for the active Windows scenario"
  value       = length(module.vm_windows_iis) > 0 ? module.vm_windows_iis[0].vmss_name : null
}

# ------------------------------------------------------------------------------
# Kubernetes cluster management & inspection outputs (Contract §1 & §7)
# ------------------------------------------------------------------------------
output "control_plane_public_ip" {
  description = "Public IP address allocated for Kubernetes control plane management access (Contract §7)"
  value       = local.cluster_enabled ? module.k8s_selfhosted[0].control_plane_public_ip : null
}

output "kube_api_port" {
  description = "Public TCP port 443 mapped through the management LB to kube-apiserver port 6443"
  value       = local.cluster_enabled ? module.k8s_selfhosted[0].kube_api_port : null
}

output "kubeconfig_path" {
  description = "Local filesystem path to cluster admin kubeconfig with public server endpoint"
  value       = local.cluster_enabled ? module.k8s_selfhosted[0].kubeconfig_path : null
}

output "kubeconfig" {
  description = "Cluster admin kubeconfig with its server endpoint rewritten to the public LB NAT mapping"
  value       = local.cluster_enabled ? module.k8s_selfhosted[0].kubeconfig : null
  sensitive   = true
}

output "control_plane_vmss_name" {
  description = "Name of the Kubernetes control plane VMSS"
  value       = local.cluster_enabled ? module.k8s_selfhosted[0].control_plane_vmss_name : null
}

output "kubectl_command_hint" {
  description = "Ready-to-paste Azure CLI command to run kubectl on the control plane via VMSS run-command"
  value       = local.cluster_enabled ? "az vmss run-command invoke -g ${azurerm_resource_group.rg.name} -n ${module.k8s_selfhosted[0].control_plane_vmss_name} --instance-id 0 --command-id RunShellScript --scripts \"kubectl get nodes -o wide\"" : null
}

output "kubeconfig_secret_name" {
  description = "Key Vault secret name holding cluster admin kubeconfig"
  value       = local.cluster_enabled ? "k8s-kubeconfig" : null
}

output "kubeconfig_fetch_command" {
  description = "Command to fetch cluster admin kubeconfig from Key Vault (valid from inside VNet / client VM)"
  value       = local.cluster_enabled ? "az keyvault secret show --vault-name ${module.keyvault_certs.key_vault_name} -n k8s-kubeconfig --query value -o tsv" : null
  sensitive   = true
}

output "operator_cidr_in_use" {
  description = "The resolved operator CIDR permitted inbound to Kubernetes API (Contract §7)"
  value       = local.cluster_enabled ? module.k8s_selfhosted[0].operator_cidr_in_use : null
}
