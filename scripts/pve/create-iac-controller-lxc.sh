#!/usr/bin/env bash
#
# create-iac-controller-lxc.sh
#
# One-time, self-contained Proxmox VE script: creates an IaC controller LXC from the
# newest Ubuntu **LTS** amd64 LXC template (prefers **minimal**, else **standard**), upgrades the guest, reboots it, masks SSH until Ansible hardens it, provisions service
# users (**tofu**, **ansible**), installs Git + Ansible, rotates a
# Proxmox API token on the host into the LXC, expects **1password-credentials.json** beside this
# script on the PVE host (removed from the PVE host only after the bootstrap **ansible-playbook** exits
# successfully inside the CT), clones this repository from GitHub, and runs
# **ansible/playbooks/iac_controller.yml** as the **ansible** user.
#
# 1Password Connect is configured to listen on all interfaces in the CT (Docker publish).
# The Proxmox **guest** firewall for this CT blocks inbound TCP to that API port on **net0**
# so the LAN cannot reach Connect; localhost and future **ACCEPT** rules (peer VM CIDRs)
# added above the DROP in the CT firewall can open access selectively.
#
# Usage (on the PVE node, as root):
#   sudo ./create-iac-controller-lxc.sh [OPTIONS]
#
# Options:
#   --vmid NUM           Container VMID (default: 600)
#   --hostname NAME      Hostname (default: iac-controller)
#   --storage NAME       Root / template storage pool (default: local-lvm)
#   --template STORE:FILE   Override template (default: auto-pick newest Ubuntu LTS amd64)
#   --template-store NAME   Storage for vztmpl download (default: local if vztmpl-capable,
#                           else --storage when it supports vztmpl, else first pvesm vztmpl store)
#   --rootfs NUM         Root disk GiB (default: 32)
#   --cores NUM          vCPU (default: 2)
#   --memory NUM         RAM MiB (default: 4096)
#   --swap NUM           Swap MiB (default: 512)
#   --bridge NAME        Bridge (default: vmbr0)
#   --ip CIDR            Static IPv4 (e.g. 192.168.6.50/24; default: dhcp)
#   --gateway IP         Default gateway (required with --ip)
#   --nameserver IP      DNS server (required with --ip; optional with DHCP)
#   --skip-template      Do not run pveam update/download
#   --replace            If --vmid already exists, stop and destroy that CT, then recreate
#   -h, --help           This text
#
# Defaults (edit for your environment):
IAC_BOOTSTRAP_REPO_URL_DEFAULT="${IAC_BOOTSTRAP_REPO_URL_DEFAULT:-https://github.com/domisjustanumber/iac-controller.git}"
IAC_DEPLOYMENT_REPO_URL_DEFAULT="${IAC_DEPLOYMENT_REPO_URL_DEFAULT:-}"
# Proxmox API token issued on the host and copied into the LXC for bootstrap (rotated each run).
IAC_PVE_TOFU_USER="${IAC_PVE_TOFU_USER:-tofu@pve}"
IAC_PVE_TOFU_TOKEN_ID="${IAC_PVE_TOFU_TOKEN_ID:-iac-controller}"

IAC_PVE_STATE_DIR="${IAC_PVE_STATE_DIR:-./iac-pve-state}"
IAC_LXC_TIMEZONE="${IAC_LXC_TIMEZONE:-}"
# Optional; must match iac_op_item_connect_token_bootstrap in ansible/inventory/group_vars/all.yml (prompt text only).
IAC_OP_CONNECT_ITEM_BOOTSTRAP="${IAC_OP_CONNECT_ITEM_BOOTSTRAP:-1Password Connect Access Token: Bootstrap}"
# 1Password vault names (shown in prompts); override with IAC_*_VAULT_DEFAULT before run.
IAC_IAC_CONTROLLER_VAULT_DEFAULT="${IAC_IAC_CONTROLLER_VAULT_DEFAULT:-IaC Controller}"
IAC_ANSIBLE_VAULT_DEFAULT="${IAC_ANSIBLE_VAULT_DEFAULT:-Ansible}"
IAC_OPENTOFU_VAULT_DEFAULT="${IAC_OPENTOFU_VAULT_DEFAULT:-OpenTofu}"
# Must match ansible/inventory/group_vars/all.yml **iac_connect_api_port** (used in PVE firewall DROP rule).
IAC_CONNECT_API_PORT="${IAC_CONNECT_API_PORT:-8080}"
# Optional; **pvesh** node name (default: **hostname -s** — must match **Datacenter → Nodes** name).
IAC_PVE_NODE_NAME="${IAC_PVE_NODE_NAME:-}"

set -euo pipefail

VMID=600
HOSTNAME=iac-controller
STORAGE=local-lvm
TEMPLATE="" # set after template selection if empty
TEMPLATE_STORE=""
ROOTFS_GB=32
CORES=2
MEMORY=4096
SWAP=512
BRIDGE=vmbr0
STATIC_IP=""
GATEWAY=""
NAMESERVER=""
SKIP_TEMPLATE=0
REPLACE_EXISTING=0
UNPRIVILEGED=1
ONBOOT=1

# Log to stderr so command substitutions like TEMPLATE="$(iac_pick_…)" only capture the volid.
log()  { printf '[%s] %s\n' "$(date -Iseconds)" "$*" >&2; }
warn() { printf '[%s] WARNING: %s\n' "$(date -Iseconds)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

iac_pct_write_guest_file_from_string() {
    local vmid="$1" guest_path="$2" content="$3" owner="${4:-root}" group="${5:-root}"
    local host_tmp
    host_tmp="$(mktemp)" || return 1
    chmod 600 "${host_tmp}"
    printf '%s' "${content}" > "${host_tmp}" || { rm -f "${host_tmp}"; return 1; }
    if ! pct push "${vmid}" "${host_tmp}" "${guest_path}"; then
        rm -f "${host_tmp}"
        return 1
    fi
    rm -f "${host_tmp}"
    pct exec "${vmid}" -- chown "${owner}:${group}" "${guest_path}"
    pct exec "${vmid}" -- chmod 600 "${guest_path}"
    return 0
}

iac_pct_write_guest_file_from_host_file() {
    local vmid="$1" guest_path="$2" host_file="$3" owner="${4:-root}" group="${5:-root}"
    [[ -r "${host_file}" ]] || die "Cannot read host file: ${host_file}"
    if ! pct push "${vmid}" "${host_file}" "${guest_path}"; then
        die "pct push failed: ${guest_path}"
    fi
    pct exec "${vmid}" -- chown "${owner}:${group}" "${guest_path}"
    pct exec "${vmid}" -- chmod 600 "${guest_path}"
}

iac_resolve_vmid_conflict() {
    pct status "${VMID}" &>/dev/null || return 0
    if [[ "${REPLACE_EXISTING}" -eq 1 ]]; then
        log "CT ${VMID} already exists; destroying (--replace)..."
        pct shutdown "${VMID}" --timeout 300 2>/dev/null || true
        pct stop "${VMID}" 2>/dev/null || true
        pct destroy "${VMID}"
        return 0
    fi
    while pct status "${VMID}" &>/dev/null; do
        printf '\n    ERROR: VMID %s is already in use. Free it or pass --vmid.\n' "${VMID}" >&2
        if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
            die "Non-interactive: choose a free VMID, or pass --replace to destroy the existing CT."
        fi
        local new_id=""
        read -r -p "  Alternative VMID (blank = abort): " new_id || true
        [[ -n "${new_id}" ]] || die "Aborted."
        VMID="${new_id}"
    done
}

# Ensure tarball ${tfile} exists on ${store} (runs pveam update + download if missing).
iac_ensure_pveam_template_file() {
    local store="$1" tfile="$2"
    command -v pveam >/dev/null || die "pveam not found"
    [[ -n "${store}" ]] || die "template store empty"
    [[ -n "${tfile}" ]] || die "template filename empty"
    if pveam list "${store}" 2>/dev/null | grep -qF "${tfile}"; then
        log "Template ${tfile} already on ${store}."
        return 0
    fi
    log "Template ${tfile} not on ${store}; updating index (pveam update)..."
    pveam update >/dev/null
    log "Downloading ${tfile} to ${store}..."
    pveam download "${store}" "${tfile}" >/dev/null
}

# Parse storage:vztmpl/name.tar.zst and ensure the image is present (unless --skip-template).
iac_ensure_pveam_vztmpl_downloaded() {
    local volid="$1"
    [[ "${SKIP_TEMPLATE}" -eq 0 ]] || return 0
    [[ "${volid}" =~ ^([^:]+):vztmpl/(.+)$ ]] || die "TEMPLATE must be storage:vztmpl/file.tar.zst (got: ${volid})"
    local store="${BASH_REMATCH[1]}"
    local tfile="${BASH_REMATCH[2]##*/}"
    iac_ensure_pveam_template_file "${store}" "${tfile}"
}

iac_storage_supports_vztmpl() {
    local s="$1"
    [[ -n "${s}" ]] || return 1
    command -v pveam >/dev/null || return 1
    pveam list "${s}" &>/dev/null
}

# First storage Proxmox exposes for vztmpl content (pvesm), or empty.
iac_first_pvesm_vztmpl_storage() {
    command -v pvesm >/dev/null || return 1
    local line id
    while IFS= read -r line; do
        id="${line%%[[:space:]]*}"
        [[ -n "${id}" ]] || continue
        [[ "${id}" == Name ]] && continue
        [[ "${id}" =~ ^[[:alnum:]_.-]+$ ]] || continue
        if iac_storage_supports_vztmpl "${id}"; then
            printf '%s' "${id}"
            return 0
        fi
    done < <(pvesm status -content vztmpl 2>/dev/null || true)
    return 1
}

iac_resolve_default_template_store() {
    local root_st="${1%%:*}"
    [[ -n "${root_st}" ]] || root_st="local"
    if iac_storage_supports_vztmpl local; then
        printf '%s' local
        return 0
    fi
    if [[ "${root_st}" != local ]] && iac_storage_supports_vztmpl "${root_st}"; then
        log "Storage 'local' is not vztmpl-capable; using '${root_st}' for templates."
        printf '%s' "${root_st}"
        return 0
    fi
    local found
    found="$(iac_first_pvesm_vztmpl_storage)" || true
    if [[ -n "${found}" ]]; then
        log "Using '${found}' for templates (local unavailable or not vztmpl-capable)."
        printf '%s' "${found}"
        return 0
    fi
    die "No vztmpl-capable storage found. Use --template-store (e.g. local)."
}

# Strip `pveam available` lines to filenames; keep only Ubuntu **LTS** amd64 (YY.04 with even YY: 22.04, 24.04, …).
# Skips interim releases (e.g. 25.04, 24.10); LTS images track long-term support and behave more predictably in LXC.
iac_avail_filter_ubuntu_lts_amd64_filenames() {
    while IFS= read -r line; do
        local fn="${line##*[[:space:]]}"
        [[ "${fn}" =~ ^ubuntu-[0-9]+\.[0-9]+- ]] || continue
        [[ "${fn}" == *amd64* ]] || continue
        [[ "${fn}" =~ ubuntu-([0-9]+)\.([0-9]+)- ]] || continue
        local maj="${BASH_REMATCH[1]}" min="${BASH_REMATCH[2]}"
        [[ "${min}" == "04" && $((maj % 2)) -eq 0 ]] || continue
        printf '%s\n' "${fn}"
    done
}

# Pick newest Ubuntu LTS amd64 LXC template: prefer *minimal*, else *standard*, else any LTS match.
iac_pick_ubuntu_lts_template() {
    local store="${1:-local}"
    command -v pveam >/dev/null || die "pveam not found"
    log "Updating template index (pveam update)..."
    pveam update >/dev/null
    local avail pool tfile
    avail="$(pveam available 2>/dev/null || true)"
    [[ -n "${avail}" ]] || die "pveam available is empty after pveam update; check network and Proxmox template lists"

    pool="$(printf '%s\n' "${avail}" | iac_avail_filter_ubuntu_lts_amd64_filenames)"
    [[ -n "${pool}" ]] || die "No Ubuntu LTS amd64 template in 'pveam available' (need e.g. ubuntu-24.04-*_amd64; YY.04 with even YY). Try: pveam update && pveam available | grep -i ubuntu"

    tfile="$(printf '%s\n' "${pool}" | grep minimal | sort -V | tail -1 || true)"
    if [[ -z "${tfile}" ]]; then
        tfile="$(printf '%s\n' "${pool}" | grep standard | sort -V | tail -1 || true)"
    fi
    if [[ -z "${tfile}" ]]; then
        tfile="$(printf '%s\n' "${pool}" | sort -V | tail -1 || true)"
    fi
    [[ -n "${tfile}" ]] || die "Could not select an Ubuntu LTS template from filtered list."

    iac_ensure_pveam_template_file "${store}" "${tfile}"
    printf '%s:vztmpl/%s' "${store}" "${tfile}"
}

# Bring up eth0 and configure static addressing via ip(8).
iac_ct_configure_network() {
    local vmid="$1" ip="$2" gw="$3" ns="${4:-}"
    log "CT${vmid}: bringing up eth0 and configuring static network..."

    pct exec "${vmid}" -- ip link set eth0 up
    sleep 2

    pct exec "${vmid}" -- ip addr add "${ip}" dev eth0 2>/dev/null || true
    pct exec "${vmid}" -- ip route add default via "${gw}" dev eth0 2>/dev/null || true
    if [[ -n "${ns}" ]]; then
        pct exec "${vmid}" -- bash -c "printf 'nameserver %s\n' '${ns}' > /etc/resolv.conf"
    fi
}

# Wait for the container to have a global IPv4 on eth0, then verify outbound connectivity.
# Uses TCP (not ping) because unprivileged LXC often lacks CAP_NET_RAW.
iac_wait_for_ct_network() {
    local vmid="$1"
    local mode="${2:-dhcp}"
    local attempts=0
    local max_ip=10
    local max_conn=45

    if [[ "${mode}" == "static" ]]; then
        log "CT${vmid}: waiting for static IPv4 on eth0..."
        max_ip=30
    else
        log "CT${vmid}: waiting for IPv4 on eth0 (DHCP)..."
    fi

    while ! pct exec "${vmid}" -- bash -c \
        'ip -4 addr show dev eth0 scope global 2>/dev/null | grep -q "inet "'; do
        attempts=$((attempts + 1))
        if [[ ${attempts} -ge ${max_ip} ]]; then
            log "CT${vmid}: no IPv4 on eth0 yet; guest links and addresses:"
            pct exec "${vmid}" -- sh -c 'ip -br link; ip -br addr' 2>&1 \
                | while IFS= read -r line; do log "  ${line}"; done || true
            if [[ "${mode}" == "static" ]]; then
                die "CT has no IPv4 on eth0 (static). Check pct config ${vmid} net0."
            else
                die "CT has no IPv4 on eth0 after DHCP. No DHCP server on bridge=${BRIDGE}? Use --ip/--gateway/--nameserver for static IP."
            fi
        fi
        sleep 2
    done

    log "CT${vmid}: waiting for outbound connectivity (TCP 1.1.1.1:443)..."
    attempts=0
    while ! pct exec "${vmid}" -- bash -c \
        'timeout 10 bash -c "exec 3<>/dev/tcp/1.1.1.1/443" 2>/dev/null'; do
        attempts=$((attempts + 1))
        [[ ${attempts} -ge ${max_conn} ]] && die \
            "CT has no outbound route to the Internet (check gateway/NAT/firewall; try --nameserver for DNS-only issues)."
        sleep 2
    done
}

iac_guest_apt_upgrade() {
    local vmid="$1"
    log "CT${vmid}: apt update && full-upgrade..."
    pct exec "${vmid}" -- bash -s <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8 LANG=C.UTF-8
apt-get update
apt-get upgrade -y -o Dpkg::Options::=--force-confold
EOS
}

# Guest reboot so kernel / upgraded libs load cleanly; restores static eth0 via ip(8) when needed.
iac_guest_reboot_after_upgrade() {
    local vmid="$1"
    local mode="${2:-dhcp}"
    local static_ip="${3:-}"
    local gateway="${4:-}"
    local nameserver="${5:-}"
    log "CT${vmid}: rebooting after apt upgrade..."
    pct shutdown "${vmid}" --timeout 300
    pct start "${vmid}"
    if [[ "${mode}" == "static" ]]; then
        [[ -n "${static_ip}" && -n "${gateway}" ]] || die "CT${vmid}: static network args missing after reboot"
        iac_ct_configure_network "${vmid}" "${static_ip}" "${gateway}" "${nameserver}"
    fi
    iac_wait_for_ct_network "${vmid}" "${mode}"
}

iac_ensure_utf8_locale() {
    local vmid="$1"
    pct exec "${vmid}" -- bash -s <<'LOCALE_EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8 LANG=C.UTF-8
apt-get update -qq
apt-get install -y -qq locales
if grep -qE '^# *en_US\.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null; then
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
elif ! grep -qE '^en_US\.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null; then
    printf '%s\n' 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
fi
locale-gen en_US.UTF-8
printf '%s\n' 'LANG=en_US.UTF-8' 'LC_ALL=en_US.UTF-8' > /etc/default/locale
LOCALE_EOF
}

iac_sync_lxc_timezone() {
    local vmid="$1" tz="${IAC_LXC_TIMEZONE:-}"
    [[ -n "${tz}" ]] && pct set "${vmid}" --delete timezone 2>/dev/null || pct set "${vmid}" --timezone host 2>/dev/null || true
    if [[ -z "${tz}" ]]; then
        tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
        [[ -z "${tz}" || "${tz}" == "n/a" ]] && tz="$(head -1 /etc/timezone 2>/dev/null | tr -d '\r\n' || true)"
        [[ -z "${tz}" ]] && tz="UTC"
    fi
    pct exec "${vmid}" -- ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime 2>/dev/null \
        || pct exec "${vmid}" -- ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
    pct exec "${vmid}" -- sh -c "printf '%s\n' '${tz}' > /etc/timezone"
}

iac_hold_ssh_until_bootstrap_guest() {
    local vmid="$1"
    log "CT${vmid}: stopping/masking SSH until bootstrap configures cursor access..."
    pct exec "${vmid}" -- bash -s <<'EOS'
set -euo pipefail
systemctl stop ssh.service 2>/dev/null || true
systemctl stop ssh.socket 2>/dev/null || true
systemctl mask ssh.service 2>/dev/null || true
systemctl mask ssh.socket 2>/dev/null || true
EOS
}

iac_provision_users_guest() {
    local vmid="$1"
    log "CT${vmid}: creating group iac-deploy and service users tofu, ansible..."
    pct exec "${vmid}" -- bash -s <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq sudo
getent group iac-deploy >/dev/null || groupadd iac-deploy
for u in tofu ansible; do
    if id -u "$u" &>/dev/null; then
        usermod -aG iac-deploy "$u"
    else
        useradd -m -s /bin/bash -G iac-deploy "$u"
    fi
done
install -d -m 0750 /etc/sudoers.d
printf '%s\n' 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/50-ansible
chmod 0440 /etc/sudoers.d/50-ansible
visudo -cf /etc/sudoers.d/50-ansible
EOS
}

iac_install_git_ansible_guest() {
    local vmid="$1"
    log "CT${vmid}: installing git, Python, Ansible (PPA when available)..."
    pct exec "${vmid}" -- bash -s <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git python3 python3-pip python3-venv software-properties-common
. /etc/os-release
if command -v add-apt-repository >/dev/null; then
    add-apt-repository --yes --update ppa:ansible/ansible 2>/dev/null || true
    apt-get update -qq || true
fi
# Install or upgrade to the newest Ansible builds available from Ubuntu / PPA.
apt-get install -y -qq ansible || apt-get install -y -qq ansible-core || { echo "ansible package missing"; exit 1; }
apt-get install -y -qq --only-upgrade ansible ansible-core 2>/dev/null || true
EOS
}

iac_install_ansible_collections_guest() {
    local vmid="$1" req="$2"
    log "CT${vmid}: installing Ansible collections as user ansible..."
    pct exec "${vmid}" -- bash -s <<EOS
set -euo pipefail
sudo -u ansible -H mkdir -p /home/ansible/.ansible/collections
sudo -u ansible -H ansible-galaxy collection install -r '${req}' -p /home/ansible/.ansible/collections --upgrade
EOS
}

iac_pve_ensure_tofu_token() {
    command -v pveum >/dev/null || die "pveum not found"
    command -v pvesh >/dev/null || die "pvesh not found"
    command -v python3 >/dev/null || die "python3 not found — required for pvesh JSON (expected on Proxmox VE)"
    local uid="${IAC_PVE_TOFU_USER}"
    local tid="${IAC_PVE_TOFU_TOKEN_ID}"
    if ! pveum user list | grep -qF "${uid}"; then
        log "Creating Proxmox user ${uid}..."
        pveum user add "${uid}" --comment "IaC controller token user"
    fi
    log "Ensuring PVEAdmin ACL for ${uid} on / ..."
    pveum acl modify / -user "${uid}" -role PVEAdmin
    local tok_path="/access/users/${uid}/token/${tid}"
    if pvesh get "${tok_path}" --output-format json &>/dev/null; then
        log "Removing existing API token ${uid}!${tid} (rotate)..."
        pvesh delete "${tok_path}" --output-format json &>/dev/null || pvesh delete "${tok_path}" || true
    fi
    log "Issuing new API token ${uid}!${tid}..."
    local secret
    secret="$(pvesh create "${tok_path}" --privsep 0 --output-format json | python3 -c '
import json, sys
obj = json.load(sys.stdin)
v = obj.get("value")
if not v:
    sys.exit(1)
print(v, end="")
')"
    printf '%s' "${uid}!${tid}=${secret}"
}

# Proxmox CT guest firewall: allow stateful flow + SSH on net0; drop Connect API on net0 (not loopback).
iac_pve_ct_firewall_connect_isolation() {
    local vmid="$1"
    local port="${2:-${IAC_CONNECT_API_PORT}}"
    command -v pvesh >/dev/null || die "pvesh not found"
    local node="${IAC_PVE_NODE_NAME:-}"
    [[ -n "${node}" ]] || node="$(hostname -s)"

    log "CT${vmid}: PVE guest firewall — block TCP ${port} (1Password Connect) on net0 from the network; allow SSH."
    warn "If rules have no effect, enable the firewall at Datacenter or node level in the Proxmox UI so guest rules apply."

    local opts="/nodes/${node}/lxc/${vmid}/firewall/options"
    local rules="/nodes/${node}/lxc/${vmid}/firewall/rules"

    pct set "${vmid}" --firewall 1
    if ! pvesh set "${opts}" --enable 1 2>/dev/null; then
        warn "pvesh set ${opts} --enable 1 failed (continuing; CT firewall may still activate)."
    fi

    pvesh create "${rules}" --action ACCEPT --type in --macro Conntrack \
        --comment "Allow established/related" \
        || die "Firewall: failed to add Conntrack rule (Proxmox macro name must match this version)."

    pvesh create "${rules}" --action ACCEPT --type in --iface net0 --proto tcp --dport 22 \
        --comment "SSH" \
        || die "Firewall: failed to add SSH ACCEPT on net0."

    pvesh create "${rules}" --action DROP --type in --iface net0 --proto tcp --dport "${port}" \
        --comment "1Password Connect API: block from net0; add ACCEPT + source above for peer VMs" \
        || die "Firewall: failed to add Connect API DROP on net0."
}

prompt_default() {
    local var_name="$1" label="$2" current="$3" input=""
    read -r -p "  ${label} [${current}]: " input || true
    printf -v "${var_name}" '%s' "${input:-${current}}"
}

prompt_required_multiline_save() {
    local host_path="$1"
    shift
    local label="$*"
    rm -f "${host_path}"
    log "  ${label}: paste / type value, then Ctrl-D on an empty line (or a single '.' line to finish)."
    ( umask 077; cat >"${host_path}" ) || { rm -f "${host_path}"; die "Failed to read secret"; }
    # Trim trailing blank lines
    sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "${host_path}" 2>/dev/null || true
    [[ -s "${host_path}" ]] || die "Secret empty: ${label}"
    chmod 600 "${host_path}"
}

usage() { head -n 53 "$0" | tail -n +2 | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)           VMID="$2"; shift 2 ;;
        --hostname)       HOSTNAME="$2"; shift 2 ;;
        --storage)        STORAGE="$2"; shift 2 ;;
        --template)       TEMPLATE="$2"; shift 2 ;;
        --template-store) TEMPLATE_STORE="$2"; shift 2 ;;
        --rootfs)         ROOTFS_GB="$2"; shift 2 ;;
        --cores)          CORES="$2"; shift 2 ;;
        --memory)         MEMORY="$2"; shift 2 ;;
        --swap)           SWAP="$2"; shift 2 ;;
        --bridge)         BRIDGE="$2"; shift 2 ;;
        --ip)             STATIC_IP="$2"; shift 2 ;;
        --gateway)        GATEWAY="$2"; shift 2 ;;
        --nameserver)     NAMESERVER="$2"; shift 2 ;;
        --skip-template)  SKIP_TEMPLATE=1; shift ;;
        --replace)        REPLACE_EXISTING=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ ${EUID} -eq 0 ]] || die "Run as root on Proxmox VE."
command -v pct >/dev/null || die "pct not found"

mkdir -p "${IAC_PVE_STATE_DIR}"
chmod 700 "${IAC_PVE_STATE_DIR}"

if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    die "This script requires an interactive terminal for secret prompts."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OP_CRED_HOST="${SCRIPT_DIR}/1password-credentials.json"
if [[ ! -f "${OP_CRED_HOST}" ]]; then
    cat <<MSG >&2
ERROR: Missing Connect credentials file next to this script:

${OP_CRED_HOST}

Download **1password-credentials.json** from 1Password for your Connect server
(Integrations / Infrastructure Secrets Automation / your server / Manage / **Credentials file**)
and save it exactly as **1password-credentials.json** in:

${SCRIPT_DIR}

MSG
    die "1password-credentials.json not found."
fi
[[ -r "${OP_CRED_HOST}" ]] || die "Not readable: ${OP_CRED_HOST}"

BOOTSTRAP_URL=""
prompt_default BOOTSTRAP_URL "GitHub bootstrap repo URL (Ansible in repo)" "${IAC_BOOTSTRAP_REPO_URL_DEFAULT}"
[[ -n "${BOOTSTRAP_URL}" ]] || die "Bootstrap repo URL required"

DEPLOY_URL=""
prompt_default DEPLOY_URL "GitHub deployment repo URL (OpenTofu)" "${IAC_DEPLOYMENT_REPO_URL_DEFAULT}"

VAULT_IAC_CTRL=""
prompt_default VAULT_IAC_CTRL "1Password vault: IaC Controller (bootstrap items; exact)" "${IAC_IAC_CONTROLLER_VAULT_DEFAULT}"
VAULT_ANSIBLE=""
prompt_default VAULT_ANSIBLE "1Password vault: Ansible (controller SSH key + Ansible token; exact)" "${IAC_ANSIBLE_VAULT_DEFAULT}"
VAULT_OPENTOFU=""
prompt_default VAULT_OPENTOFU "1Password vault: OpenTofu (OpenTofu token, secrets; exact)" "${IAC_OPENTOFU_VAULT_DEFAULT}"
trim_vault() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
VAULT_IAC_CTRL="$(trim_vault "${VAULT_IAC_CTRL}")"
VAULT_ANSIBLE="$(trim_vault "${VAULT_ANSIBLE}")"
VAULT_OPENTOFU="$(trim_vault "${VAULT_OPENTOFU}")"
[[ -n "${VAULT_IAC_CTRL}" && -n "${VAULT_ANSIBLE}" && -n "${VAULT_OPENTOFU}" ]] || die "All three vault names are required"

OP_TOKEN_BOOTSTRAP_HOST="$(umask 077; mktemp "${IAC_PVE_STATE_DIR}/op-token-bootstrap.XXXXXX")"
prompt_required_multiline_save "${OP_TOKEN_BOOTSTRAP_HOST}" \
    "1Password Connect Bootstrap access token (item \"${IAC_OP_CONNECT_ITEM_BOOTSTRAP}\" / Integrations — first playbook run reads secrets from Connect on localhost after it starts)"

EXTRA_HOST="$(mktemp "${IAC_PVE_STATE_DIR}/extra-vars.XXXXXX.yml")"
trap 'rm -f "${OP_TOKEN_BOOTSTRAP_HOST}" "${EXTRA_HOST}"' EXIT
cat >"${EXTRA_HOST}" <<YAML
iac_iac_controller_vault: "$(printf '%s' "${VAULT_IAC_CTRL}" | sed 's/"/\\"/g')"
iac_ansible_vault: "$(printf '%s' "${VAULT_ANSIBLE}" | sed 's/"/\\"/g')"
iac_opentofu_vault: "$(printf '%s' "${VAULT_OPENTOFU}" | sed 's/"/\\"/g')"
iac_deployment_repo_url: "$(printf '%s' "${DEPLOY_URL}" | sed 's/"/\\"/g')"
iac_github_app_client_id: ""
iac_github_installation_id: ""
YAML

iac_resolve_vmid_conflict

log "Prompts finished; continuing unattended (template pull, CT create, apt, Ansible)."

if [[ -z "${TEMPLATE_STORE}" ]]; then
    TEMPLATE_STORE="$(iac_resolve_default_template_store "${STORAGE}")"
fi

if [[ -z "${TEMPLATE}" ]]; then
    [[ "${SKIP_TEMPLATE}" -eq 0 ]] || die "Set --template when using --skip-template"
    TEMPLATE="$(iac_pick_ubuntu_lts_template "${TEMPLATE_STORE}")"
else
    [[ "${TEMPLATE}" =~ ^[^:]+:vztmpl/.+ ]] || die "TEMPLATE must be storage:vztmpl/file.tar.zst"
    iac_ensure_pveam_vztmpl_downloaded "${TEMPLATE}"
fi

ROOT_PW="$(openssl rand -base64 24)"
( umask 077; printf '%s\n' "${ROOT_PW}" >"${IAC_PVE_STATE_DIR}/iac-controller-ct${VMID}.root.password" )
PASSWORD_FILE="${IAC_PVE_STATE_DIR}/iac-controller-ct${VMID}.root.password"
chmod 600 "${PASSWORD_FILE}"
log "Generated root password file: ${PASSWORD_FILE}"

PCT_ARGS=(
    "${VMID}" "${TEMPLATE}"
    --hostname "${HOSTNAME}"
    --storage "${STORAGE}"
    --rootfs "${STORAGE}:${ROOTFS_GB}"
    --cores "${CORES}"
    --memory "${MEMORY}"
    --swap "${SWAP}"
    --password "${ROOT_PW}"
    --unprivileged "${UNPRIVILEGED}"
    --features "nesting=1"
    --onboot "${ONBOOT}"
    --start 0
)

NET0="name=eth0,bridge=${BRIDGE},firewall=1,type=veth"
if [[ -n "${STATIC_IP}" ]]; then
    [[ "${STATIC_IP}" == */* ]] || die "--ip must include CIDR mask (e.g. 192.168.6.50/24)"
    [[ -n "${GATEWAY}" ]] || die "--gateway is required when using --ip"
    [[ -n "${NAMESERVER}" ]] || die "--nameserver is required when using --ip"
    NET0+=",ip=${STATIC_IP},gw=${GATEWAY}"
else
    NET0+=",ip=dhcp"
fi
PCT_ARGS+=(--net0 "${NET0}")
[[ -n "${NAMESERVER}" ]] && PCT_ARGS+=(--nameserver "${NAMESERVER}")

log "Creating CT ${VMID} (${HOSTNAME})..."
pct create "${PCT_ARGS[@]}"

pct start "${VMID}"
if [[ -n "${STATIC_IP}" ]]; then
    iac_ct_configure_network "${VMID}" "${STATIC_IP}" "${GATEWAY}" "${NAMESERVER}"
    iac_wait_for_ct_network "${VMID}" static
else
    iac_wait_for_ct_network "${VMID}" dhcp
fi

iac_pve_ct_firewall_connect_isolation "${VMID}"

iac_ensure_utf8_locale "${VMID}"
iac_sync_lxc_timezone "${VMID}"
iac_guest_apt_upgrade "${VMID}"
if [[ -n "${STATIC_IP}" ]]; then
    iac_guest_reboot_after_upgrade "${VMID}" static "${STATIC_IP}" "${GATEWAY}" "${NAMESERVER}"
else
    iac_guest_reboot_after_upgrade "${VMID}" dhcp
fi
iac_provision_users_guest "${VMID}"
iac_hold_ssh_until_bootstrap_guest "${VMID}"
iac_install_git_ansible_guest "${VMID}"

pct exec "${VMID}" -- mkdir -p /opt/iac-connect
iac_pct_write_guest_file_from_host_file "${VMID}" /opt/iac-connect/credentials.json "${OP_CRED_HOST}" "root" "root"

pct exec "${VMID}" -- mkdir -p /home/tofu/.config/op /home/ansible/.config/op
pct exec "${VMID}" -- chown -R tofu:tofu /home/tofu/.config
pct exec "${VMID}" -- chown -R ansible:ansible /home/ansible/.config
iac_pct_write_guest_file_from_host_file "${VMID}" /home/ansible/.config/op/connect_token "${OP_TOKEN_BOOTSTRAP_HOST}" "ansible" "ansible"

log "Rotating Proxmox API token for ${IAC_PVE_TOFU_USER}!${IAC_PVE_TOFU_TOKEN_ID}..."
PVE_API_TOKEN_LINE="$(iac_pve_ensure_tofu_token)"
pct exec "${VMID}" -- mkdir -p /home/tofu/.config/iac-controller
iac_pct_write_guest_file_from_string "${VMID}" /home/tofu/.config/iac-controller/pve_api_token "${PVE_API_TOKEN_LINE}" "tofu" "tofu"

CLONE_DIR="/opt/iac-bootstrap"
pct exec "${VMID}" -- rm -rf "${CLONE_DIR}"
pct exec "${VMID}" -- mkdir -p /opt
pct exec "${VMID}" -- git clone --depth 1 "${BOOTSTRAP_URL}" "${CLONE_DIR}"

REQ="${CLONE_DIR}/ansible/requirements.yml"
pct exec "${VMID}" -- test -f "${REQ}" || die "Missing ${REQ} in cloned repo"

iac_install_ansible_collections_guest "${VMID}" "${REQ}"

PLAY="${CLONE_DIR}/ansible/playbooks/iac_controller.yml"
pct exec "${VMID}" -- test -f "${PLAY}" || die "Missing playbook ${PLAY}"

EXTRA_GUEST="/tmp/iac-extra-vars.yml"
pct push "${VMID}" "${EXTRA_HOST}" "${EXTRA_GUEST}"
pct exec "${VMID}" -- chown ansible:ansible "${EXTRA_GUEST}"
pct exec "${VMID}" -- chmod 600 "${EXTRA_GUEST}"

log "CT${VMID}: running IaC controller Ansible playbook as user ansible..."
set +e
pct exec "${VMID}" -- env \
    ANSIBLE_CONFIG="${CLONE_DIR}/ansible/ansible.cfg" \
    ANSIBLE_COLLECTIONS_PATH="/home/ansible/.ansible/collections" \
    HOME=/home/ansible \
    USER=ansible \
    bash -lc "sudo -u ansible -H ansible-playbook -i '${CLONE_DIR}/ansible/inventory/hosts.yml' '${PLAY}' -e '@${EXTRA_GUEST}'"
PB_RC=$?
set -e
pct exec "${VMID}" -- rm -f "${EXTRA_GUEST}"
[[ "${PB_RC}" -eq 0 ]] || die "Ansible playbook failed (exit ${PB_RC})."

rm -f "${OP_CRED_HOST}"
log "Removed local Connect credentials file ${OP_CRED_HOST} (Ansible bootstrap in CT${VMID} succeeded)."

log "Ensuring Proxmox API token file is absent on guest..."
pct exec "${VMID}" -- rm -f /home/tofu/.config/iac-controller/pve_api_token
pct exec "${VMID}" -- test ! -f /home/tofu/.config/iac-controller/pve_api_token || die "Token file still present."

log "Done. CT${VMID} (${HOSTNAME}) root password in ${PASSWORD_FILE}. SSH: only user cursor (public key from 1Password item Cursor SSH Public Key / field public_key), sudo; see README."
trap - EXIT
rm -f "${OP_TOKEN_BOOTSTRAP_HOST}"
