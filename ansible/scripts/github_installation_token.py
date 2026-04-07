#!/usr/bin/env python3
"""Exchange a GitHub App JWT for an installation access token (stdout: token only). Uses openssl (RSA RS256, Ed25519 EdDSA)."""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def _canon_traditional_pem(text: str) -> str:
    """Strip junk around one PEM block; collapse and re-wrap base64 so openssl parses PKCS#1/PKCS#8 text reliably."""
    if "BEGIN OPENSSH PRIVATE KEY" in text:
        return text
    if "PROC-TYPE:" in text.upper():
        return text
    m = re.search(
        r"-----BEGIN ([^-]+)-----\s*(.*?)\s*-----END \1-----",
        text,
        re.DOTALL,
    )
    if not m:
        return text
    label, body = m.group(1).strip(), m.group(2)
    inner = "".join(body.split())
    if not inner or not re.fullmatch(r"[A-Za-z0-9+/=]+", inner):
        return text
    wrapped = "\n".join(inner[j : j + 64] for j in range(0, len(inner), 64))
    return f"-----BEGIN {label}-----\n{wrapped}\n-----END {label}-----\n"


def b64url_json(obj: dict) -> str:
    raw = json.dumps(obj, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _prepare_pem_file(pem_path: str) -> None:
    """Normalize text from 1Password (BOM, CRLF, literal \\n) and convert OpenSSH keys to PEM."""
    path = Path(pem_path)
    raw = path.read_bytes()
    text = raw.decode("utf-8-sig")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if "\\n" in text and "-----BEGIN" in text:
        text = text.replace("\\n", "\n")
    text = text.strip()
    if (len(text) > 1 and text[0] == text[-1] == '"') or (len(text) > 1 and text[0] == text[-1] == "'"):
        text = text[1:-1].strip()

    u = text.upper()
    if "ENCRYPTED PRIVATE KEY" in u or "PROC-TYPE: 4,ENCRYPTED" in u or (
        "BEGIN RSA PRIVATE KEY" in u and "ENCRYPTED" in u
    ):
        raise RuntimeError(
            "Private key is passphrase-encrypted; GitHub App download or re-export an **unencrypted** PEM."
        )

    head = text[:500]
    if "BEGIN OPENSSH PRIVATE KEY" not in head:
        text = _canon_traditional_pem(text)

    if not text.endswith("\n"):
        text += "\n"
    path.write_text(text, encoding="utf-8")
    os.chmod(path, 0o600)

    if "BEGIN OPENSSH PRIVATE KEY" in text[:500]:
        proc = subprocess.run(
            [
                "ssh-keygen",
                "-p",
                "-P",
                "",
                "-N",
                "",
                "-m",
                "PEM",
                "-f",
                str(path),
            ],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                "OPENSSH private key could not be converted to PEM (passphrase or old ssh-keygen?). "
                + (proc.stderr or proc.stdout or "").strip()
            )
        backup = Path(str(path) + ".old")
        if backup.is_file():
            try:
                backup.unlink()
            except OSError:
                pass


def _key_kind(pem_path: str) -> str:
    proc = subprocess.run(
        ["openssl", "pkey", "-in", pem_path, "-noout", "-text"],
        capture_output=True,
        text=True,
    )
    blob = ((proc.stdout or "") + (proc.stderr or "")).upper()
    if proc.returncode != 0:
        proc_rsa = subprocess.run(
            ["openssl", "rsa", "-in", pem_path, "-noout", "-text"],
            capture_output=True,
            text=True,
        )
        if proc_rsa.returncode == 0:
            return "rsa"
        err = (proc.stderr or proc.stdout or "").strip()
        err_rsa = (proc_rsa.stderr or proc_rsa.stdout or "").strip()
        raise RuntimeError(
            "openssl could not read the private key (truncated PEM, bad paste, or passphrase?). "
            f"pkey: {err}; rsa: {err_rsa}"
        )
    if "ED25519" in blob:
        return "ed25519"
    if "EC PRIVATE" in blob or "PRIME256V1" in blob or "P-256" in blob:
        return "ec"
    if "RSA" in blob:
        return "rsa"
    raise RuntimeError(
        "Could not infer key type from `openssl pkey -text`; expected RSA, Ed25519, or EC P-256 PEM."
    )


def b64url_sign_rsa(signing_input: str, pem_path: str) -> str:
    proc = subprocess.run(
        ["openssl", "dgst", "-binary", "-sha256", "-sign", pem_path],
        input=signing_input.encode(),
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            (proc.stderr.decode() if proc.stderr else "") or "openssl rsa sign failed"
        )
    return base64.urlsafe_b64encode(proc.stdout).rstrip(b"=").decode("ascii")


def b64url_sign_ed25519(signing_input: str, pem_path: str) -> str:
    proc = subprocess.run(
        ["openssl", "pkeyutl", "-sign", "-inkey", pem_path, "-rawin"],
        input=signing_input.encode(),
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            (proc.stderr.decode() if proc.stderr else "") or "openssl ed25519 sign failed"
        )
    return base64.urlsafe_b64encode(proc.stdout).rstrip(b"=").decode("ascii")


def gh_jwt(client_id: str, pem_path: str) -> str:
    now = int(time.time())
    kind = _key_kind(pem_path)
    if kind == "ed25519":
        hdr = b64url_json({"alg": "EdDSA", "typ": "JWT"})
        sign = b64url_sign_ed25519
    elif kind == "rsa":
        hdr = b64url_json({"alg": "RS256", "typ": "JWT"})
        sign = b64url_sign_rsa
    else:
        raise RuntimeError(
            "This GitHub App key is EC (ES256). Regenerate the app key as **RSA** or **Ed25519** "
            "in GitHub Developer Settings, or extend this script for ES256."
        )
    payload = b64url_json({"iat": now - 60, "exp": now + 540, "iss": client_id})
    signing_input = f"{hdr}.{payload}"
    sig = sign(signing_input, pem_path)
    return f"{signing_input}.{sig}"


def github_api(jwt_token: str, method: str, path: str, body: dict | None = None) -> tuple[int, bytes]:
    data = None
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {jwt_token}",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(
        f"https://api.github.com{path}",
        data=data,
        headers=headers,
        method=method,
    )
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as resp:
            return resp.getcode(), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--client-id", required=True)
    p.add_argument("--installation-id", default="")
    p.add_argument("--repo-url", default="")
    p.add_argument("--pem-path", required=True)
    args = p.parse_args()

    try:
        _prepare_pem_file(args.pem_path)
        app_jwt = gh_jwt(args.client_id, args.pem_path)
    except RuntimeError as e:
        print(str(e), file=sys.stderr)
        return 1

    inst = args.installation_id.strip()
    if not inst:
        if not args.repo_url:
            print("Need --installation-id or --repo-url", file=sys.stderr)
            return 1
        u = args.repo_url.replace("https://github.com/", "").replace("http://github.com/", "")
        u = u.split("?")[0].split("#")[0]
        if u.endswith(".git"):
            u = u[:-4]
        parts = u.split("/", 1)
        if len(parts) != 2:
            print("Bad repo URL", file=sys.stderr)
            return 1
        owner, repo = parts
        code, raw = github_api(app_jwt, "GET", f"/repos/{owner}/{repo}/installation", None)
        if code != 200:
            sys.stderr.buffer.write(raw)
            sys.stderr.write("\n")
            return 1
        inst = str(json.loads(raw.decode())["id"])

    code, raw = github_api(app_jwt, "POST", f"/app/installations/{inst}/access_tokens", {})
    if code != 201:
        sys.stderr.buffer.write(raw)
        sys.stderr.write("\n")
        return 1
    print(json.loads(raw.decode())["token"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
