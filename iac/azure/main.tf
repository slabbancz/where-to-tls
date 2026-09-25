terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

# Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "wtt-${var.env}-rg"
  location = var.location
  tags     = var.tags
}

locals {
  is_k8s_scenario = contains([
    "c0-cluster-only",
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
    "c4-k8s-pod-net-plain",
    "c4-k8s-pod-java-plain",
    "c4-k8s-pod-go-plain"
    , "c4-k8s-pod-rust-plain"
  ], var.active_scenario)

  # Cluster infrastructure is independent of the selected benchmark scenario.
  cluster_enabled = true

  is_windows_vm = var.active_scenario == "s1-iis-netfx"

  is_linux_vm_scenario = contains([
    "c0-vm-only",
    "s2-vm-net",
    "s2-vm-java",
    "s2-vm-go",
    "s2-vm-rust",
    "c2-vm-net-plain",
    "c2-vm-java-plain",
    "c2-vm-go-plain",
    "c2-vm-rust-plain"
  ], var.active_scenario)

  # Stack determination
  active_stack = (
    var.active_scenario == "s1-iis-netfx" ? "netfx48" :
    contains(["s2-vm-net", "s4-k8s-pod-net", "s5-traefik-passthrough-net", "s6-traefik-terminate-net", "c2-vm-net-plain", "c4-k8s-pod-net-plain"], var.active_scenario) ? "net10" :
    contains(["s2-vm-java", "s4-k8s-pod-java", "s5-traefik-passthrough-java", "s6-traefik-terminate-java", "c2-vm-java-plain", "c4-k8s-pod-java-plain"], var.active_scenario) ? "java-netty" :
    contains(["s2-vm-rust", "s4-k8s-pod-rust", "s5-traefik-passthrough-rust", "s6-traefik-terminate-rust", "c2-vm-rust-plain", "c4-k8s-pod-rust-plain"], var.active_scenario) ? "rust" :
    "go"
  )

  # Keep both worker pools stable while benchmark scenarios change.
  k8s_capacity_workload = var.k8s_capacity_workload
  k8s_capacity_traefik  = var.k8s_capacity_traefik
}
