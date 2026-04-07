#!/usr/bin/env python3
"""Exchange a GitHub App JWT for an installation access token (stdout: token only). Uses openssl (RSA RS256, Ed25519 EdDSA)."""
from __future__ import annotations

import argparse
import base64
import json
import subprocess
import ssl
import sys
import time
import urllib.error
import urllib.request


def b64url_json(obj: dict) -> str:
    raw = json.dumps(obj, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _key_kind(pem_path: str) -> str:
    proc = subprocess.run(
        ["openssl", "pkey", "-in", pem_path, "-noout", "-text"],
        capture_output=True,
        text=True,
    )
    blob = ((proc.stdout or "") + (proc.stderr or "")).upper()
    if proc.returncode != 0:
        raise RuntimeError(
            "openssl could not read the private key (wrong PEM or passphrase?). "
            + (proc.stderr or proc.stdout or "").strip()
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
