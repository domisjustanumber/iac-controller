# Managed by iac-controller — mirrors **scripts/pve/create-iac-controller-lxc.sh**
# **iac_pve_ct_firewall_connect_isolation** (guest firewall on net0).
# Credentials: **PROXMOX_VE_ENDPOINT**, **PROXMOX_VE_API_TOKEN**, **PROXMOX_VE_INSECURE** (see bpg/proxmox provider).
# Import (once): tofu import -state=<path> proxmox_virtual_environment_firewall_rules.iac_controller_guest 'container/<node>/<vmid>'

provider "proxmox" {
}

resource "proxmox_virtual_environment_firewall_rules" "iac_controller_guest" {
  node_name    = var.node_name
  container_id = var.container_id

  rule {
    type    = "in"
    action  = "ACCEPT"
    macro   = "Conntrack"
    comment = "Allow established/related"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    iface   = "net0"
    proto   = "tcp"
    dport   = "22"
    comment = "SSH"
  }
  rule {
    type    = "in"
    action  = "DROP"
    iface   = "net0"
    proto   = "tcp"
    dport   = tostring(var.connect_api_port)
    comment = "1Password Connect API: block from net0; add ACCEPT + source above for peer VMs"
  }
}
