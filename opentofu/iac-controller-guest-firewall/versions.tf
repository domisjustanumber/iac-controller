# Version floors verified April 2026 against registry.opentofu.org and GitHub releases.
terraform {
  required_version = ">= 1.11.5, < 2.0.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.100.0, < 1.0.0"
    }
  }
}
