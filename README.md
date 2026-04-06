# iac-controller — IaC controller toolkit

This repository is a **small toolkit** used from **Proxmox VE** to create an **IaC controller LXC**: Ubuntu LTS template (minimal preferred), **1Password Connect**, **Docker**, **OpenTofu**, and an **Ansible** playbook that wires them together. A **deployment** Git repository (OpenTofu configuration) is cloned into `/home/opentofu/deployment` on the controller by the playbook when you provide its URL during provisioning.

---

## Layout

| Path | Role |
|------|------|
| `scripts/pve/create-iac-controller-lxc.sh` | **One-shot, copy to the PVE host** together with **`1password-credentials.json`** in the same directory (from 1Password for your Connect server). Creates the CT, provisions users, disables SSH, stages Connect credentials under **`/opt/iac-connect`**, Proxmox token material, clones this repo to `/opt/iac-bootstrap`, runs the playbook as `ansible`. Deletes the local credentials file after **success** only. |
| `ansible/playbooks/iac_controller.yml` | Controller configuration on the LXC: Docker, **1Password Connect** (localhost only; **`/opt/iac-connect`** holds credentials + compose), OpenTofu apt, optional GitHub App clone of the deployment repo, `tofu init`, unattended upgrades, syncing the Proxmox API token into 1Password. Uses the **bootstrap** Connect token (from disk) for **all** Connect API calls in this play—the only token that can read the OpenTofu and Ansible items. After **success**, `/home/ansible/.config/op/connect_token` is replaced with the narrower **Ansible** token for future runs. On **failure**, that path is removed. |
| `ansible/requirements.yml` | Ansible collections: `community.general`, `community.docker`, `onepassword.connect`. |
| `ansible/inventory/`, `ansible/templates/` | Local inventory (`localhost`) and Connect **Docker Compose** template. |
| `ansible/scripts/github_installation_token.py` | Helper for GitHub App installation tokens (used by the playbook). |
| `scripts/iac-controller/validate.sh` | On the controller (or any checkout): `tofu fmt` / `validate` and optional yamllint, ansible-lint, hadolint. Defaults to `IAC_REPO_ROOT=/home/opentofu/deployment`. |

---

## Provisioning overview (`create-iac-controller-lxc.sh`)

1. **Template**: Newest **Ubuntu LTS** **minimal** (else standard) amd64 image from `pveam` (override with `--template` / `--template-store` / `--skip-template`).
2. **Guest**: `apt` update + upgrade, UTF-8 locale, optional `IAC_LXC_TIMEZONE`.
3. **Users**: `opentofu`, `ansible` ( **`ansible`** has passwordless sudo for Ansible `become`). **1Password Connect** runs in Docker only; there is no Linux `1password` or `opuser` account on the host (`opuser` exists only inside the images).
4. **SSH**: **Disabled** in the guest (services masked). Use **`pct exec`**, the Proxmox **console**, or automation from the host.
5. **Host files / prompts**: **`1password-credentials.json`** next to the script (see layout table); missing file → abort with instructions; **success** → local file deleted. **TTY prompts**: bootstrap Git URL (this repo), deployment Git URL (infrastructure repo), **Bootstrap** Connect API token (from **`1Password Connect Access Token: Bootstrap`** → **`/home/ansible/.config/op/connect_token`** for **`iac_controller.yml`** only), exact **1Password vault name**. The playbook uses that bootstrap token against localhost Connect to read vault secrets, writes **`/home/opentofu/.config/op/connect_token`** from **`1Password Connect Access Token: OpenTofu`**, then on **success** replaces the ansible path with the **Ansible** token for later runs.
6. **Proxmox API token**: Created/rotated on the **PVE host** for `IAC_PVE_TOFU_USER` + `IAC_PVE_TOFU_TOKEN_ID`, granted an ACL (see below; the script currently uses **`PVEAdmin` on `/`** for simplicity), copied into the guest, then removed after the playbook succeeds once the token is stored in 1Password.
7. **Bootstrap clone**: This repo → `/opt/iac-bootstrap`; collections install as **`ansible`**; **`iac_controller.yml`** runs as **`ansible`**.

**Defaults** at the top of the script (edit or export before run):

- `IAC_BOOTSTRAP_REPO_URL_DEFAULT` — Git URL for **this** repository (default **`https://github.com/domisjustanumber/iac-controller.git`**).
- `IAC_DEPLOYMENT_REPO_URL_DEFAULT` — optional default deployment repo URL.
- `IAC_PVE_TOFU_USER` (default `opentofu@pve`), `IAC_PVE_TOFU_TOKEN_ID` (default `iac-controller`).
- `IAC_PVE_STATE_DIR` — host directory for generated secrets (e.g. root password file).
- `IAC_OP_CONNECT_ITEM_BOOTSTRAP` — optional override for the bootstrap item title in the PVE script prompt (default **`1Password Connect Access Token: Bootstrap`**).

**Host dependencies**: `python3` for JSON from `pvesh` and the 1Password Connect API (expected on Proxmox VE).

**Upgrading from older installs** of this toolkit: rename or recreate vault items to match `ansible/inventory/group_vars/all.yml`, migrate **Connect** from `/home/1password/` to **`/opt/iac-connect`** (credentials + compose) if you still use the old layout, align the guest with `iac_opentofu_*` (or override those variables in extra vars), remove the obsolete Linux `1password` user if present, and re-run the playbook.

---

## 1Password (Connect) items

The playbook and prompts assume items in the vault you name at install time. Titles are configurable in `ansible/inventory/group_vars/all.yml`; defaults:

| Item title | Purpose |
|------------|---------|
| `1Password Connect Access Token: OpenTofu` | Concealed **`credential`**: **Connect access token** for **`opentofu`**. **`iac_controller.yml`** reads it with the **bootstrap** token and writes `/home/opentofu/.config/op/connect_token`. |
| `1Password Connect Access Token: Bootstrap` | Concealed **`credential`**: **bootstrap** token (pasted on the PVE host → `/home/ansible/.config/op/connect_token`). Only this token can read the OpenTofu and Ansible Connect items during the bootstrap play. Removed from disk after **failed** run; on **success** replaced by the **Ansible** item below. |
| `1Password Connect Access Token: Ansible` | Concealed **`credential`**: **Connect access token** for ongoing Ansible use (**narrower** access than bootstrap). Must exist in the vault before bootstrap succeeds; the playbook reads it with the **bootstrap** token and writes `/home/ansible/.config/op/connect_token` after a **successful** run. |
| `OpenTofu/PVE_API_Key` | Concealed field **`credential`**: full Proxmox API token value (`user@realm!tokenid=secret`). Written by the playbook from the bootstrap file, then the file is deleted. |
| `OpenTofu/state_file` | Concealed **`state_json`**: optional **state** blob restored to the deployment workspace when no local state file exists yet (same basename as `iac_opentofu_state_file` in `group_vars`; subject to 1Password size limits). |
| `GitHub App` | Fields **`Client_secret`** (PEM), **`Client_ID`**, optional **`Installation_ID`** — used to clone **HTTPS `github.com`** deployment repos privately. |

---

## Tighter ACLs for the OpenTofu API user

The provisioning script currently runs:

```text
pveum acl modify / -user opentofu@pve -role PVEAdmin
```

That matches a quick-start default but is **broader than OpenTofu** needs. Prefer a **dedicated role** and **scoped paths** once everything is stable.

### Suggested custom role (LXC + storage–focused)

The exact privilege set depends on your modules (cloud-init, clone-from-template, SDN, PCI, backups). A practical **starting point** for [`bpg/proxmox`](https://search.opentofu.org/provider/bpg/proxmox/latest) managing **LXCs** and disks on a known node and datastore:

```bash
pveum role add OpenTofu-LXC -privs "\
Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,\
Pool.Allocate,\
VM.Allocate,VM.Audit,VM.Clone,\
VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,\
VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,\
VM.Monitor,VM.PowerManagement"
```

Then attach the user **only where needed** (repeat for each node/storage pool the provider touches):

```bash
NODE="$(hostname -s)"   # or your cluster node name
STORE="local-lvm"     # your storage id(s)

pveum acl modify "/nodes/${NODE}" -user opentofu@pve -role OpenTofu-LXC
pveum acl modify "/storage/${STORE}" -user opentofu@pve -role OpenTofu-LXC
```

If you use a **resource pool** for new IDs, grant the same role on the pool path (see `pveum acl list` / Proxmox **Datacenter → Permissions**).

**Often required extras** (add to the role or as separate ACLs after errors):

| Need | Typical privilege / note |
|------|---------------------------|
| **SDN / VNet** bridges | May need **`SDN.Allocate`** or broader network permissions depending on UI/API usage. |
| **Firewall** rules on guests | Sometimes requires **`VM.Config.Options`** already; cluster firewall can need **`Sys.Modify`** (try to avoid; scope narrowly). |
| **Secrets / TPM** | **`VM.Config.HWType`** / provider-specific features may need more than the list above. |
| **Read-only plan** without apply | Split users: one role with `VM.Audit` + `Datastore.Audit` only on read paths. |

**Process**: start with `OpenTofu-LXC`, run `tofu plan`; if Proxmox returns **403**, add the missing privilege (Proxmox and the provider docs are the source of truth). When happy, **remove** `/` + `PVEAdmin` for `opentofu@pve` and rely only on the scoped ACLs.

To align the **script** with this, replace the `pveum acl modify / … PVEAdmin` stanza in `scripts/pve/create-iac-controller-lxc.sh` with your role and `pveum acl modify` lines (or document a one-time manual ACL step after first install).

---

## Typical workflow

**On the Proxmox host (root), interactive shell:**

```bash
cp /path/to/iac-controller/scripts/pve/create-iac-controller-lxc.sh /root/iac-pve-state/
chmod +x /root/iac-pve-state/create-iac-controller-lxc.sh
/root/iac-pve-state/create-iac-controller-lxc.sh
```

**Inside the controller** (no SSH; from PVE):

```bash
pct exec <VMID> -- bash -lc 'sudo -u opentofu -H tofu -chdir=/home/opentofu/deployment version'
pct exec <VMID> -- bash -lc 'sudo -u ansible -H ansible-playbook -i /opt/iac-bootstrap/ansible/inventory/hosts.yml /opt/iac-bootstrap/ansible/playbooks/iac_controller.yml --check'
```

**Validation** on the deployment checkout:

```bash
IAC_REPO_ROOT=/home/opentofu/deployment /opt/iac-bootstrap/scripts/iac-controller/validate.sh
```

Override `IAC_REPO_ROOT` or `IAC_TOFU_CHDIR` if your `.tf` files live in a subdirectory (for example `tofu/`).

---

## Related documentation

- [Proxmox VE — User management (pveum)](https://pve.proxmox.com/pve-docs/chapter-pveum.html)  
- [Proxmox VE — Wiki: User Management](https://pve.proxmox.com/wiki/User_Management)  
- [1Password Connect — Ansible collection](https://developer.1password.com/docs/connect/ansible-collection/)  
- [OpenTofu — installation (.deb)](https://opentofu.org/docs/intro/install/deb/)  
- [bpg/proxmox provider (OpenTofu registry)](https://search.opentofu.org/provider/bpg/proxmox/latest)

Your **deployment** repository should document environments, backends, and any cluster-specific naming (`NODE`, storage IDs, bridges).
