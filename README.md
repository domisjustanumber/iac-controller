# iac-controller — IaC controller toolkit

This repository is a **small toolkit** used from **Proxmox VE** to create an **IaC controller LXC**: Ubuntu LTS template (minimal preferred), **1Password Connect**, **Docker**, **OpenTofu**, and an **Ansible** playbook that wires them together. A **deployment** Git repository (OpenTofu configuration) is cloned into `/home/tofu/deployment` on the controller by the playbook when you provide its URL during provisioning. That tree is owned by **`tofu:iac-deploy`** (setgid) so both **`tofu`** and **`ansible`** can use the same checkout.

---

## Layout

| Path | Role |
|------|------|
| `scripts/pve/create-iac-controller-lxc.sh` | **One-shot, copy to the PVE host** together with **`1password-credentials.json`** in the same directory (from 1Password for your Connect server). Creates the CT, provisions users, **masks SSH until the playbook** configures it, stages Connect credentials under **`/opt/iac-connect`**, Proxmox token material, clones this repo to `/opt/iac-bootstrap`, runs the playbook as `ansible`. Deletes **`1password-credentials.json` on the PVE host** only after **`iac_controller.yml` exits successfully inside the CT** (not merely after CT creation). |
| `ansible/playbooks/iac_controller.yml` | Controller configuration on the LXC: Docker, **1Password Connect**, OpenTofu apt, optional deployment repo clone, **`tofu init`**. **OpenTofu state files never persist under the deployment tree**: bootstrap uses a **temp directory** for **`terraform.tfstate`** and **`iac-controller-guest-firewall.tfstate`**, restores from / pushes to **1Password**, then deletes the temp dir. **Deployment root**: optional **read-only `tofu plan`** (never apply during bootstrap)—if there is drift, **`create-iac-controller-lxc.sh`** prints the **last log line** to say so. **Controller guest firewall** only: **`tofu import`** if needed, **`tofu plan` / `apply` with `-target=`** `proxmox_virtual_environment_firewall_rules.iac_controller_guest`. Unattended upgrades; PVE API token into 1Password. **Bootstrap** Connect token (from disk) must reach vaults **`IaC Controller`**, **`Ansible`**, **`OpenTofu`**; it installs narrower tokens for **`tofu`** / **`ansible`**. On **failure**, the ansible token path is removed. |
| `ansible/requirements.yml` | Ansible collections: `community.general`, `community.docker`, `onepassword.connect`. |
| `ansible/ansible.cfg` | `allow_world_readable_tmpfiles` so **`become_user: tofu`** (and similar) on **localhost** does not fail when GNU `chmod` rejects ACL-style modes (Ansible 2.20+). The bootstrap script sets **`ANSIBLE_CONFIG`** to this file. |
| `ansible/inventory/`, `ansible/templates/` | Local inventory (`localhost`) and Connect **Docker Compose** template. |
| `ansible/scripts/github_installation_token.py` | Helper for GitHub App installation tokens (used by the playbook). |
| `opentofu/iac-controller-guest-firewall/` | OpenTofu root module (`bpg/proxmox`) for the **IaC controller LXC guest firewall** rules (SSH, Connect API port DROP on **net0**; no Conntrack macro—handled on host **PVEFW-FORWARD**). Copied into **`/home/tofu/deployment/iac-controller-guest-firewall`** during bootstrap; **state exists only in 1Password** (`iac-controller-guest-firewall.tfstate` payload at runtime is ephemeral). |
| `scripts/iac-controller/validate.sh` | On the controller (or any checkout): `tofu fmt` / `validate` and optional yamllint, ansible-lint, hadolint. Defaults to `IAC_REPO_ROOT=/home/tofu/deployment`. |

---

## Provisioning overview (`create-iac-controller-lxc.sh`)

1. **Template**: Newest **Ubuntu LTS** **minimal** (else standard) amd64 image from `pveam` (override with `--template` / `--template-store` / `--skip-template`).
2. **Guest**: `apt` update + upgrade, UTF-8 locale, optional `IAC_LXC_TIMEZONE`.
3. **Users**: `tofu`, `ansible`, and POSIX group **`iac-deploy`** (both service users are members). **`ansible`** has passwordless sudo for Ansible `become`; **`tofu`** does not. Interactive SSH uses **`cursor`** only (see below). **1Password Connect** runs in Docker only; there is no Linux `1password` or `opuser` account on the host (`opuser` exists only inside the images).
4. **SSH**: The PVE script **stops and masks** `ssh` until **`iac_controller.yml`** finishes. The playbook then enables **`openssh-server`** with **`/etc/ssh/sshd_config.d/99-iac-controller.conf`**: **`AllowUsers cursor`**, **public-key only** (`AuthenticationMethods publickey`, no password auth), **`PermitRootLogin no`**. The **`cursor`** user’s **`authorized_keys`** line is **read** from 1Password (**IaC Controller** vault, Secure Note **`Cursor SSH Public Key`**, custom field **`public_key`** — use a **text** or **password / concealed** field; one line, the same as a standard **`ssh-ed25519` / `ssh-rsa` / `ecdsa-*` `.pub`** for the identity you use with Cursor / Remote SSH). **`cursor`** has passwordless **`sudo`**. Use **`pct exec`**, the Proxmox console, or **`ssh cursor@…`** (controller hostname or IP) after bootstrap.
5. **Host files / prompts**: **`1password-credentials.json`** next to the script (see layout table); missing file → abort with instructions; that file is **removed from the PVE host only after the bootstrap playbook succeeds inside the CT**. **TTY prompts**: bootstrap Git URL (this repo), deployment Git URL (infrastructure repo), **three 1Password vault names** (**`IaC Controller`**, **`Ansible`**, **`OpenTofu`** — defaults match these exactly), **Bootstrap** Connect API token (pasted → **`/home/ansible/.config/op/connect_token`** for **`iac_controller.yml`** only). The playbook uses that bootstrap token against localhost Connect (it must be allowed to read/write all three vaults as needed). It reads **`1Password Connect Access Token: OpenTofu`** and **`… Ansible`** from the **IaC Controller** vault and writes those values to **`/home/tofu/.config/op/connect_token`** and (after success) **`/home/ansible/.config/op/connect_token`**, respectively, for **more restrictive** Connect access on later **`tofu`** / **`ansible-playbook`** runs.
6. **Proxmox API token**: Created/rotated on the **PVE host** for `IAC_PVE_TOFU_USER` + `IAC_PVE_TOFU_TOKEN_ID`, granted an ACL (see below; the script currently uses **`PVEAdmin` on `/`** for simplicity), copied into the guest for bootstrap only, then stored in 1Password as **`OpenTofu PVE API Key`** and **removed from the guest** after a successful sync (see playbook + PVE script).
7. **Bootstrap clone**: This repo → `/opt/iac-bootstrap`; collections install as **`ansible`**; **`iac_controller.yml`** runs as **`ansible`**.
8. **OpenTofu / Proxmox from the CT**: The playbook receives **`iac_pve_api_endpoint`**, **`iac_pve_node_name`**, and **`iac_controller_lxc_vmid`** via Ansible extra-vars. The create script sets them after the CT exists (defaults: node = **`hostname -s`** on the PVE host, VMID = chosen **`--vmid`**, API URL = **`IAC_PVE_API_ENDPOINT`** or **`--pve-api-url`** or **`https://<first host IP>:8006/`**). Use an address the **LXC can reach** on port **8006** if the auto default is wrong.

**Defaults** at the top of the script (edit or export before run):

- `IAC_BOOTSTRAP_REPO_URL_DEFAULT` — Git URL for **this** repository (default **`https://github.com/domisjustanumber/iac-controller.git`**).
- `IAC_DEPLOYMENT_REPO_URL_DEFAULT` — optional default deployment repo URL.
- `IAC_PVE_TOFU_USER` (default `tofu@pve`), `IAC_PVE_TOFU_TOKEN_ID` (default `iac-controller`). The create script **creates** that PVE user when absent (`pvesh get /access/users/…`, not a table **grep**, so ids like `my-tofu@pve` do not hide a missing `tofu@pve`). Set **`IAC_PVE_TOFU_USER`** if you use another account (e.g. **`opentofu@pve`**).
- `IAC_PVE_STATE_DIR` — host directory for generated secrets (e.g. root password file).
- `IAC_OP_CONNECT_ITEM_BOOTSTRAP` — optional override for the bootstrap item title in the PVE script prompt (default **`1Password Connect Access Token: Bootstrap`**).
- `IAC_IAC_CONTROLLER_VAULT_DEFAULT`, `IAC_ANSIBLE_VAULT_DEFAULT`, `IAC_OPENTOFU_VAULT_DEFAULT` — default answers for the three vault prompts (defaults **`IaC Controller`**, **`Ansible`**, **`OpenTofu`**).
- `IAC_PVE_API_ENDPOINT` — optional full HTTPS API URL (with trailing `/`) passed through to Ansible; overrides the default derived from **`hostname -I`** on the PVE host. CLI: **`--pve-api-url`**.
- `IAC_PVE_NODE_NAME` — optional cluster node name for OpenTofu import (default **`hostname -s`** on the PVE host when the script runs).

**Host dependencies**: `python3` for JSON from `pvesh` and the 1Password Connect API (expected on Proxmox VE).

---

## 1Password (Connect) items

Secrets use split keys: `iac_iac_controller_vault`, `iac_ansible_vault`, `iac_opentofu_vault` in `group_vars`. The **bootstrap** token must reach **all three** during `iac_controller.yml`. **`1Password Connect Access Token: Ansible`** and **`… OpenTofu`** live in the **IaC Controller** vault; bootstrap reads them and stores the values on disk for **`tofu`** and **`ansible`** (tighten each token’s vault access in 1Password to **OpenTofu** / **Ansible** respectively). Titles are configurable in `group_vars`; defaults:

| Vault | Item title | Purpose |
|-------|------------|---------|
| **IaC Controller** | `GitHub App` | Concealed **`Private_Key`**: the GitHub App **private key PEM** (`-----BEGIN RSA PRIVATE KEY-----` block downloaded from Developer Settings → Private keys). **`Client_ID`**: the Client ID from the same page (used as JWT `iss`). Optional **`Installation_ID`** (otherwise derived from the deployment repo URL). |
| **IaC Controller** | `Cursor SSH Public Key` | **Secure Note**: custom field labeled exactly **`public_key`** — **text** or **password / concealed** (Connect exposes the value to **`field_info`** either way). Not only the main Notes area. One line: **SSH public key** (same as your `.pub` for Cursor / Remote SSH) for **`cursor`**’s **`authorized_keys`**. The **bootstrap** Connect token must be allowed to read this item. |
| **IaC Controller** | `1Password Connect Access Token: Bootstrap` | *(Reference; value is pasted on the PVE host.)* Optional concealed **`credential`** item for documentation. |
| **IaC Controller** | `1Password Connect Access Token: Ansible` | Concealed **`credential`**: **narrower** Connect token for future **`ansible-playbook`** / automation. Bootstrap reads it from this vault and writes `/home/ansible/.config/op/connect_token` after a **successful** run (configure this token in 1Password to only need the **Ansible** vault). |
| **IaC Controller** | `1Password Connect Access Token: OpenTofu` | Concealed **`credential`**: **narrower** Connect token for the **`tofu`** Linux user. Bootstrap reads it from this vault and writes `/home/tofu/.config/op/connect_token` (configure this token in 1Password to only need the **OpenTofu** vault). |
| **Ansible** | `Ansible SSH Key` | **SSH Key** (`SSH_KEY`): concealed **`private key`** (PEM); 1Password derives **`public key`**. Bootstrap `POST`s via Connect (**`ansible.builtin.uri`**; **`generic_item`** does not support `ssh_key`). Optional `GET` refresh after create, else local `.pub`. Installs **`/home/ansible/.ssh/id_ed25519`** (+ `.pub`). |
| **OpenTofu** | `Ansible SSH Public Key` | **SSH Key** (`SSH_KEY`): concealed **`public_key`** only (no **`private key`** field). OpenTofu reads that line for cloud-init / **`authorized_keys`**. Replace when the line differs from the Ansible key’s **`public key`** or a **`private key`** field is still present. |
| **OpenTofu** | `OpenTofu PVE API Key` | **Secure Note**, concealed **`credential`**: full Proxmox API token. Pushed from bootstrap staging, then the local file is removed after a successful sync. |
| **OpenTofu** | `OpenTofu state file` | Concealed **`state_json`**: deployment workspace **`terraform.tfstate`**. Bootstrap **never leaves this file** under **`/home/tofu/deployment`**; it is restored to a **temp path** for **`tofu init` / plan / slurp**, then **re-pushed** when non-empty. Subject to 1Password field size limits. |
| **OpenTofu** | `OpenTofu controller guest firewall` | **Secure Note**, concealed **`state_json`**: OpenTofu state for **`iac-controller-guest-firewall.tfstate`** (`proxmox_virtual_environment_firewall_rules`). **Create this item** in the OpenTofu vault before bootstrap (same field name as the main state item). Bootstrap **imports** when needed, **plans/applies with `-target=`** that resource only, **pushes** updated state, and **removes** temp state from disk. |

---

## Tighter ACLs for the OpenTofu API user

The provisioning script currently runs:

```text
pveum acl modify / -user tofu@pve -role PVEAdmin
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

pveum acl modify "/nodes/${NODE}" -user tofu@pve -role OpenTofu-LXC
pveum acl modify "/storage/${STORE}" -user tofu@pve -role OpenTofu-LXC
```

If you use a **resource pool** for new IDs, grant the same role on the pool path (see `pveum acl list` / Proxmox **Datacenter → Permissions**).

**Often required extras** (add to the role or as separate ACLs after errors):

| Need | Typical privilege / note |
|------|---------------------------|
| **SDN / VNet** bridges | May need **`SDN.Allocate`** or broader network permissions depending on UI/API usage. |
| **Firewall** rules on guests | Sometimes requires **`VM.Config.Options`** already; cluster firewall can need **`Sys.Modify`** (try to avoid; scope narrowly). |
| **Secrets / TPM** | **`VM.Config.HWType`** / provider-specific features may need more than the list above. |
| **Read-only plan** without apply | Split users: one role with `VM.Audit` + `Datastore.Audit` only on read paths. |

**Process**: start with `OpenTofu-LXC`, run `tofu plan`; if Proxmox returns **403**, add the missing privilege (Proxmox and the provider docs are the source of truth). When happy, **remove** `/` + `PVEAdmin` for `tofu@pve` and rely only on the scoped ACLs.

To align the **script** with this, replace the `pveum acl modify / … PVEAdmin` stanza in `scripts/pve/create-iac-controller-lxc.sh` with your role and `pveum acl modify` lines (or document a one-time manual ACL step after first install).

---

## Typical workflow

**On the Proxmox host (root), interactive shell:**

```bash
cp /path/to/iac-controller/scripts/pve/create-iac-controller-lxc.sh /root/iac-pve-state/
chmod +x /root/iac-pve-state/create-iac-controller-lxc.sh
/root/iac-pve-state/create-iac-controller-lxc.sh
```

**Inside the controller** (from PVE, or SSH as **`cursor`** after bootstrap):

```bash
pct exec <VMID> -- bash -lc 'sudo -u tofu -H tofu -chdir=/home/tofu/deployment version'
pct exec <VMID> -- env ANSIBLE_CONFIG=/opt/iac-bootstrap/ansible/ansible.cfg bash -lc 'sudo -u ansible -H ansible-playbook -i /opt/iac-bootstrap/ansible/inventory/hosts.yml /opt/iac-bootstrap/ansible/playbooks/iac_controller.yml --check'
# or: ssh -i ~/.ssh/your_cursor_private_key cursor@<controller-hostname-or-ip>
```

**Validation** on the deployment checkout:

```bash
IAC_REPO_ROOT=/home/tofu/deployment /opt/iac-bootstrap/scripts/iac-controller/validate.sh
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
