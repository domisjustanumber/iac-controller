variable "node_name" {
  type        = string
  description = "Proxmox node name (short hostname from Datacenter → Nodes)."
}

variable "container_id" {
  type        = number
  description = "IaC controller LXC VMID (pct / Proxmox CT id)."
}

variable "connect_api_port" {
  type        = number
  description = "TCP port published by 1Password Connect on the CT (must match ansible iac_connect_api_port / PVE DROP rule)."
  default     = 8080
}
