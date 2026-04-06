#!/usr/bin/env bash
#
# validate.sh — OpenTofu fmt/validate and optional linters (YAML, Ansible, Dockerfiles).
#
# Intended for the deployment checkout on the controller (default `/home/opentofu/deployment`)
# or any monorepo that mixes OpenTofu (`.tf`) with `ansible/`, `config/`, or Dockerfiles.
#
# Usage:
#   ./scripts/iac-controller/validate.sh [OPTIONS]
#
# Options:
#   --sync                git fetch + checkout origin/<ref> in IAC_REPO_ROOT
#   --opentofu-only       Skip yamllint / ansible-lint / hadolint
#   --install-lint-tools  pip install --user yamllint ansible-lint before lint steps
#
# Environment:
#   IAC_REPO_ROOT      Git checkout root (default: /home/opentofu/deployment)
#   IAC_TOFU_CHDIR     Directory for tofu -chdir (default: tofu/ under repo if present, else repo root)
#   IAC_GIT_REF        Branch for --sync (default: main)

set -euo pipefail

SYNC=0
OPENTOFU_ONLY=0
INSTALL_LINT=0

usage() {
    sed -n '1,22p' "$0" | tail -n +2
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        --sync) SYNC=1; shift ;;
        --opentofu-only) OPENTOFU_ONLY=1; shift ;;
        --install-lint-tools) INSTALL_LINT=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="${IAC_REPO_ROOT:-/home/opentofu/deployment}"
GIT_REF="${IAC_GIT_REF:-main}"

[[ -d "${REPO_ROOT}/.git" ]] || {
    echo "ERROR: Git repo not found at ${REPO_ROOT} (set IAC_REPO_ROOT)" >&2
    exit 2
}

cd "${REPO_ROOT}"

if [[ "${SYNC}" -eq 1 ]]; then
    git fetch origin
    git checkout -B "${GIT_REF}" "origin/${GIT_REF}"
fi

if [[ -n "${IAC_TOFU_CHDIR:-}" ]]; then
    TOFU_CHDIR="${IAC_TOFU_CHDIR}"
elif [[ -d "${REPO_ROOT}/tofu" ]]; then
    TOFU_CHDIR="${REPO_ROOT}/tofu"
else
    TOFU_CHDIR="${REPO_ROOT}"
fi

[[ -d "${TOFU_CHDIR}" ]] || {
    echo "ERROR: OpenTofu directory not found: ${TOFU_CHDIR}" >&2
    exit 2
}

echo "==> OpenTofu fmt (check) in ${TOFU_CHDIR}"
tofu -chdir="${TOFU_CHDIR}" fmt -check

echo "==> OpenTofu init (no backend) + validate"
tofu -chdir="${TOFU_CHDIR}" init -backend=false
tofu -chdir="${TOFU_CHDIR}" validate

if [[ "${OPENTOFU_ONLY}" -eq 1 ]]; then
    echo "validate.sh: OK (OpenTofu only)"
    exit 0
fi

if [[ "${INSTALL_LINT}" -eq 1 ]]; then
    echo "==> pip install --user (yamllint, ansible-lint)"
    python3 -m pip install --user --quiet yamllint ansible-lint
    export PATH="${HOME}/.local/bin:${PATH}"
fi

yamllint_paths=()
[[ -d "${REPO_ROOT}/ansible" ]] && yamllint_paths+=("${REPO_ROOT}/ansible")
[[ -d "${REPO_ROOT}/config" ]] && yamllint_paths+=("${REPO_ROOT}/config")

if [[ "${#yamllint_paths[@]}" -gt 0 ]]; then
    if ! command -v yamllint &>/dev/null; then
        echo "yamllint not found. Install: python3 -m pip install --user yamllint" >&2
        echo "  or pass --install-lint-tools" >&2
        exit 1
    fi
    echo "==> yamllint"
    yamllint -s "${yamllint_paths[@]}"
else
    echo "==> yamllint (skipped — no ansible/ or config/)"
fi

if [[ -d "${REPO_ROOT}/ansible" ]]; then
    if ! command -v ansible-lint &>/dev/null; then
        echo "ansible-lint not found. Install: python3 -m pip install --user ansible-lint" >&2
        echo "  or pass --install-lint-tools" >&2
        exit 1
    fi
    echo "==> ansible-lint"
    ansible-lint "${REPO_ROOT}/ansible/"
else
    echo "==> ansible-lint (skipped — no ansible/)"
fi

if command -v hadolint &>/dev/null; then
    echo "==> hadolint (Dockerfiles under ${REPO_ROOT})"
    mapfile -t dockerfiles < <(find "${REPO_ROOT}" -name Dockerfile -type f 2>/dev/null | sort)
    if [[ "${#dockerfiles[@]}" -gt 0 ]]; then
        hadolint "${dockerfiles[@]}"
    else
        echo "  (no Dockerfiles)"
    fi
else
    echo "hadolint not installed — skipping (optional)"
fi

echo "validate.sh: OK"
