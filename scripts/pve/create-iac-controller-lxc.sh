#!/usr/bin/env bash
#
# create-iac-controller-lxc.sh
#
# One-time, self-contained Proxmox VE script: creates an IaC controller LXC from the
# latest Ubuntu **minimal** template, upgrades the guest, disables SSH, provisions service
# users (**1password**, **opentofu**, **ansible**), installs Git + Ansible, rotates a
# Proxmox API token on the host into the LXC, expects **1password-credentials.json** beside this
# script on the PVE host (removed after a successful run), clones this repository from GitHub, and runs
# **ansible/playbooks/iac_controller.yml** as the **ansible** user.
#
# Usage (on the PVE node, as root):
#   sudo ./create-iac-controller-lxc.sh [OPTIONS]
#
# Options:
#   --vmid NUM           Container VMID (default: 600)
#   --hostname NAME      Hostname (default: iac-controller)
#   --storage NAME       Root / template storage pool (default: local-lvm)
#   --template STORE:FILE   Override template (default: auto-pick latest ubuntu minimal on STORE)
#   --template-store NAME   Storage for minimal image download (default: first field of --storage)
#   --rootfs NUM         Root disk GiB (default: 32)
#   --cores NUM          vCPU (default: 2)
#   --memory NUM         RAM MiB (default: 4096)
#   --swap NUM           Swap MiB (default: 512)
#   --bridge NAME        Bridge (default: vmbr0)
#   --nameserver IP      Optional DNS (omit = DHCP)
#   --skip-template      Do not run pveam update/download
#   -h, --help           This text
#
# Defaults (edit for your environment):
IAC_BOOTSTRAP_REPO_URL_DEFAULT="${IAC_BOOTSTRAP_REPO_URL_DEFAULT:-https://github.com/domisjustanumber/iac-controller.git}"
IAC_DEPLOYMENT_REPO_URL_DEFAULT="${IAC_DEPLOYMENT_REPO_URL_DEFAULT:-}"
# Proxmox API token issued on the host and copied into the LXC for bootstrap (rotated each run).
IAC_PVE_TOFU_USER="${IAC_PVE_TOFU_USER:-opentofu@pve}"
IAC_PVE_TOFU_TOKEN_ID="${IAC_PVE_TOFU_TOKEN_ID:-iac-controller}"

IAC_PVE_STATE_DIR="${IAC_PVE_STATE_DIR:-./iac-pve-state}"
IAC_LXC_TIMEZONE="${IAC_LXC_TIMEZONE:-}"
# Must match ansible/inventory/group_vars/all.yml (iac_op_item_connect_token_*)
IAC_OP_CONNECT_ITEM_OPENTOFU="${IAC_OP_CONNECT_ITEM_OPENTOFU:-1Password Connect Access Token: OpenTofu}"
IAC_OP_CONNECT_ITEM_BOOTSTRAP="${IAC_OP_CONNECT_ITEM_BOOTSTRAP:-1Password Connect Access Token: Bootstrap}"

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
NAMESERVER=""
SKIP_TEMPLATE=0
UNPRIVILEGED=1
ONBOOT=1

log()  { printf '[%s] %s\n' "$(date -Iseconds)" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date -Iseconds)" "$*" >&2; }
die()  { log "ERROR: $*" >&2; exit 1; }

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
    while pct status "${VMID}" &>/dev/null; do
        cat <<MSG >&2

ERROR: VMID ${VMID} is already in use. Free it or pass --vmid.
MSG
        if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
            die "Non-interactive: choose a free VMID."
        fi
        local new_id=""
        read -r -p "  Alternative VMID (blank = abort): " new_id || true
        [[ -n "${new_id}" ]] || die "Aborted."
        VMID="${new_id}"
    done
}

iac_pick_minimal_ubuntu_template() {
    local store="${1:-local}"
    command -v pveam >/dev/null || die "pveam not found"
    log "Updating template index (pveam update)..."
    pveam update
    local tfile
    tfile="$(pveam available 2>/dev/null | awk '$2 ~ /ubuntu-/ && $2 ~ /minimal/ && $2 ~ /amd64/ {print $2}' | sort -V | tail -1 || true)"
    [[ -n "${tfile}" ]] || die "Could not find an ubuntu minimal amd64 template in 'pveam available'"
    if ! pveam list "${store}" 2>/dev/null | grep -qF "${tfile}"; then
        log "Downloading ${tfile} to ${store}..."
        pveam download "${store}" "${tfile}"
    else
        log "Template ${tfile} already on ${store}."
    fi
    printf '%s:vztmpl/%s' "${store}" "${tfile}"
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

iac_disable_ssh_guest() {
    local vmid="$1"
    log "CT${vmid}: disabling SSH (mask ssh.service / socket)..."
    pct exec "${vmid}" -- bash -s <<'EOS'
set -euo pipefail
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl disable --now ssh.service 2>/dev/null || true
systemctl mask ssh.service 2>/dev/null || true
systemctl mask ssh.socket 2>/dev/null || true
EOS
}

iac_provision_users_guest() {
    local vmid="$1"
    log "CT${vmid}: creating service users 1password, opentofu, ansible..."
    pct exec "${vmid}" -- bash -s <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq sudo
for u in 1password opentofu ansible; do
    id -u "$u" &>/dev/null || useradd -m -s /bin/bash "$u"
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
apt-get install -y -qq ca-certificates curl gnupg git python3 python3-pip python3-venv
. /etc/os-release
if add-apt-repository --help &>/dev/null; then
    add-apt-repository --yes --update ppa:ansible/ansible 2>/dev/null || true
    apt-get update -qq || true
fi
apt-get install -y -qq ansible || apt-get install -y -qq ansible-core || { echo "ansible package missing"; exit 1; }
EOS
}

iac_install_ansible_collections_guest() {
    local vmid="$1" req="$2"
    log "CT${vmid}: installing Ansible collections as user ansible..."
    pct exec "${vmid}" -- bash -s <<EOS
set -euo pipefail
sudo -u ansible -H mkdir -p /home/ansible/.ansible/collections
sudo -u ansible -H ansible-galaxy collection install -r '${req}' -p /home/ansible/.ansible/collections
EOS
}

iac_pve_ensure_opentofu_token() {
    command -v pveum >/dev/null || die "pveum not found"
    command -v pvesh >/dev/null || die "pvesh not found"
    command -v jq >/dev/null || die "jq not found (apt install jq)"
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
    secret="$(pvesh create "${tok_path}" --privsep 0 --output-format json | jq -er '.value')"
    printf '%s' "${uid}!${tid}=${secret}"
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
    umask 077
    rm -f "${host_path}"
    log "  ${label}: paste / type value, then Ctrl-D on an empty line (or a single '.' line to finish)."
    if ! cat >"${host_path}"; then
        rm -f "${host_path}"
        die "Failed to read secret"
    fi
    # Trim trailing blank lines
    sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "${host_path}" 2>/dev/null || true
    [[ -s "${host_path}" ]] || die "Secret empty: ${label}"
    chmod 600 "${host_path}"
}

usage() { head -n 52 "$0" | tail -n +2 | sed 's/^# \{0,1\}//'; }

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
        --nameserver)     NAMESERVER="$2"; shift 2 ;;
        --skip-template)  SKIP_TEMPLATE=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ ${EUID} -eq 0 ]] || die "Run as root on Proxmox VE."
command -v pct >/dev/null || die "pct not found"

iac_resolve_vmid_conflict

mkdir -p "${IAC_PVE_STATE_DIR}"
chmod 700 "${IAC_PVE_STATE_DIR}"

if [[ -z "${TEMPLATE_STORE}" ]]; then
    TEMPLATE_STORE="${STORAGE%%:*}"
    [[ -n "${TEMPLATE_STORE}" ]] || TEMPLATE_STORE="local"
fi

if [[ -z "${TEMPLATE}" ]]; then
    [[ "${SKIP_TEMPLATE}" -eq 0 ]] || die "Set --template when using --skip-template"
    TEMPLATE="$(iac_pick_minimal_ubuntu_template "${TEMPLATE_STORE}")"
else
    [[ "${TEMPLATE}" =~ ^[^:]+:.+ ]] || die "TEMPLATE must be storage:vztmpl/file.tar.zst"
fi

if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    die "This script requires an interactive terminal for secret prompts."
fi

ROOT_PW="$(openssl rand -base64 24)"
umask 077
PASSWORD_FILE="${IAC_PVE_STATE_DIR}/iac-controller-ct${VMID}.root.password"
printf '%s\n' "${ROOT_PW}" >"${PASSWORD_FILE}"
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
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp"
)
[[ -n "${NAMESERVER}" ]] && PCT_ARGS+=(--nameserver "${NAMESERVER}")

log "Creating CT ${VMID} (${HOSTNAME})..."
pct create "${PCT_ARGS[@]}"

pct start "${VMID}"
attempts=0
while ! pct exec "${VMID}" -- ping -c1 -W2 1.1.1.1 &>/dev/null; do
    attempts=$((attempts + 1))
    [[ ${attempts} -ge 40 ]] && die "CT has no network."
    sleep 2
done

iac_ensure_utf8_locale "${VMID}"
iac_sync_lxc_timezone "${VMID}"
iac_guest_apt_upgrade "${VMID}"
iac_provision_users_guest "${VMID}"
iac_disable_ssh_guest "${VMID}"
iac_install_git_ansible_guest "${VMID}"

BOOTSTRAP_URL=""
prompt_default BOOTSTRAP_URL "GitHub bootstrap repo URL (Ansible in repo)" "${IAC_BOOTSTRAP_REPO_URL_DEFAULT}"
[[ -n "${BOOTSTRAP_URL}" ]] || die "Bootstrap repo URL required"

DEPLOY_URL=""
prompt_default DEPLOY_URL "GitHub deployment repo URL (OpenTofu)" "${IAC_DEPLOYMENT_REPO_URL_DEFAULT}"

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

umask 077
OP_TOKEN_OPENTOFU_HOST="$(mktemp "${IAC_PVE_STATE_DIR}/op-token-opentofu.XXXXXX")"
OP_TOKEN_BOOTSTRAP_HOST="$(mktemp "${IAC_PVE_STATE_DIR}/op-token-bootstrap.XXXXXX")"
trap 'rm -f "${OP_TOKEN_OPENTOFU_HOST}" "${OP_TOKEN_BOOTSTRAP_HOST}" "${EXTRA_HOST}"' EXIT
prompt_required_multiline_save "${OP_TOKEN_OPENTOFU_HOST}" \
    "1Password Connect access token for user opentofu (item \"${IAC_OP_CONNECT_ITEM_OPENTOFU}\", concealed field credential — not credentials.json)"
prompt_required_multiline_save "${OP_TOKEN_BOOTSTRAP_HOST}" \
    "1Password Connect Bootstrap user API key for Ansible bootstrap (item \"${IAC_OP_CONNECT_ITEM_BOOTSTRAP}\" from vault, or paste token from Integrations — used by iac_controller.yml to read secrets from Connect)"

VAULT_NAME=""
read -r -p "  1Password vault name for IaC (exact): " VAULT_NAME || true
[[ -n "${VAULT_NAME}" ]] || die "Vault name required"

EXTRA_HOST="$(mktemp "${IAC_PVE_STATE_DIR}/extra-vars.XXXXXX.yml")"
cat >"${EXTRA_HOST}" <<YAML
iac_onepassword_vault: "$(printf '%s' "${VAULT_NAME}" | sed 's/"/\\"/g')"
iac_deployment_repo_url: "$(printf '%s' "${DEPLOY_URL}" | sed 's/"/\\"/g')"
iac_github_app_client_id: ""
iac_github_installation_id: ""
YAML

iac_pct_write_guest_file_from_host_file "${VMID}" /home/1password/credentials.json "${OP_CRED_HOST}" "1password" "1password"

pct exec "${VMID}" -- mkdir -p /home/opentofu/.config/op /home/ansible/.config/op
pct exec "${VMID}" -- chown -R opentofu:opentofu /home/opentofu/.config
pct exec "${VMID}" -- chown -R ansible:ansible /home/ansible/.config
iac_pct_write_guest_file_from_host_file "${VMID}" /home/opentofu/.config/op/connect_token "${OP_TOKEN_OPENTOFU_HOST}" "opentofu" "opentofu"
iac_pct_write_guest_file_from_host_file "${VMID}" /home/ansible/.config/op/connect_token "${OP_TOKEN_BOOTSTRAP_HOST}" "ansible" "ansible"

log "Rotating Proxmox API token for ${IAC_PVE_TOFU_USER}!${IAC_PVE_TOFU_TOKEN_ID}..."
PVE_API_TOKEN_LINE="$(iac_pve_ensure_opentofu_token)"
pct exec "${VMID}" -- mkdir -p /home/opentofu/.config/iac-controller
iac_pct_write_guest_file_from_string "${VMID}" /home/opentofu/.config/iac-controller/pve_api_token "${PVE_API_TOKEN_LINE}" "opentofu" "opentofu"

CLONE_DIR="/opt/iac-bootstrap"
pct exec "${VMID}" -- rm -rf "${CLONE_DIR}"
pct exec "${VMID}" -- mkdir -p /opt
pct exec "${VMID}" -- git clone --depth 1 "${BOOTSTRAP_URL}" "${CLONE_DIR}"

REQ="${CLONE_DIR}/ansible/requirements.yml"
[[ -f "${REQ}" ]] || die "Missing ${REQ} in cloned repo"

iac_install_ansible_collections_guest "${VMID}" "${REQ}"

PLAY="${CLONE_DIR}/ansible/playbooks/iac_controller.yml"
[[ -f "${PLAY}" ]] || die "Missing playbook ${PLAY}"

EXTRA_GUEST="/tmp/iac-extra-vars.yml"
pct push "${VMID}" "${EXTRA_HOST}" "${EXTRA_GUEST}"
pct exec "${VMID}" -- chmod 600 "${EXTRA_GUEST}"

log "CT${VMID}: running IaC controller Ansible playbook as user ansible..."
set +e
pct exec "${VMID}" -- env \
    ANSIBLE_COLLECTIONS_PATH="/home/ansible/.ansible/collections" \
    HOME=/home/ansible \
    USER=ansible \
    bash -lc "sudo -u ansible -H ansible-playbook -i '${CLONE_DIR}/ansible/inventory/hosts.yml' '${PLAY}' -e '@${EXTRA_GUEST}'"
PB_RC=$?
set -e
pct exec "${VMID}" -- rm -f "${EXTRA_GUEST}"
[[ "${PB_RC}" -eq 0 ]] || die "Ansible playbook failed (exit ${PB_RC})."

log "Ensuring Proxmox API token file is absent on guest..."
pct exec "${VMID}" -- rm -f /home/opentofu/.config/iac-controller/pve_api_token
pct exec "${VMID}" -- test ! -f /home/opentofu/.config/iac-controller/pve_api_token || die "Token file still present."

rm -f "${OP_CRED_HOST}"
log "Removed local Connect credentials file ${OP_CRED_HOST}"

log "Done. CT${VMID} (${HOSTNAME}) root password in ${PASSWORD_FILE}. SSH is disabled; use pct exec or Proxmox console."
trap - EXIT
rm -f "${OP_TOKEN_OPENTOFU_HOST}" "${OP_TOKEN_BOOTSTRAP_HOST}"
