#!/usr/bin/env python3
# Lee secretos descifrados por SOPS desde stdin y los carga en Vault
# Uso: sops -d all.enc.yaml | python3 load-secrets-to-vault.py
import sys
import yaml
import subprocess

data = yaml.safe_load(sys.stdin)

for app, secrets in data.items():
    if not isinstance(secrets, dict):
        continue
    args = ["kubectl", "exec", "-n", "vault", "vault-0", "--",
            "vault", "kv", "put", f"secret/{app}"]
    args += [f"{k}={v}" for k, v in secrets.items()]
    print(f"    -> secret/{app}")
    subprocess.run(args, check=True)
