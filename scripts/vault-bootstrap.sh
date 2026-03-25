#!/bin/bash
# vault-bootstrap.sh — configura Vault y recarga secretos tras recrear el cluster
# Uso: ./scripts/vault-bootstrap.sh
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGE_KEY="$REPO_ROOT/.sops/age/keys.txt"
SECRETS_DIR="$REPO_ROOT/secrets"

echo "==> Esperando a que Vault esté listo..."
kubectl wait --for=condition=Ready pod/vault-0 -n vault --timeout=90s

# ── 1. Kubernetes auth ──────────────────────────────────────────────────────
echo ""
echo "==> Configurando Kubernetes auth..."

kubectl exec -n vault vault-0 -- vault auth enable kubernetes 2>/dev/null \
  || echo "    (kubernetes auth ya estaba habilitado)"

kubectl exec -n vault vault-0 -- sh -c '
  vault write auth/kubernetes/config \
    kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"
'

kubectl exec -n vault vault-0 -- sh -c '
  cat > /tmp/eso-policy.hcl << EOF
path "secret/data/*" {
  capabilities = ["read"]
}
EOF
  vault policy write eso-policy /tmp/eso-policy.hcl
'

kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/eso-role \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-policy \
  ttl=24h

# ── 2. Secretos ─────────────────────────────────────────────────────────────
echo ""
echo "==> Cargando secretos en Vault..."

for enc_file in "$SECRETS_DIR"/*.enc.yaml; do
  app=$(basename "$enc_file" .enc.yaml)
  echo "    → secret/$app"

  kv_args=$(SOPS_AGE_KEY_FILE="$AGE_KEY" sops -d "$enc_file" | \
    python3 -c "
import sys
lines = []
for line in sys.stdin:
    line = line.rstrip()
    if line.startswith('sops:'):
        break
    if ': ' in line:
        key, val = line.split(': ', 1)
        lines.append(f'{key.strip()}={val.strip()}')
print(' '.join(lines))
")

  kubectl exec -n vault vault-0 -- vault kv put "secret/$app" $kv_args
done

# ── 3. Recrear ClusterSecretStore para reconectar con Vault ─────────────────
echo ""
echo "==> Reconectando ClusterSecretStore con Vault..."
kubectl delete clustersecretstore vault-cluster-store --ignore-not-found
kubectl apply -f "$REPO_ROOT/manifests/infrastructure/vault/cluster-secret-store.yaml"
kubectl wait --for=jsonpath='{.status.conditions[0].status}'=True \
  clustersecretstore/vault-cluster-store --timeout=30s

# ── 4. Forzar re-sync de todos los ExternalSecrets ──────────────────────────
echo ""
echo "==> Forzando re-sync de ExternalSecrets..."
kubectl get externalsecret -A --no-headers | while read ns name _rest; do
  kubectl annotate externalsecret "$name" -n "$ns" \
    force-sync=$(date +%s) --overwrite 2>/dev/null
done

echo ""
echo "==> Listo. Estado final:"
kubectl get clustersecretstore vault-cluster-store
kubectl get externalsecret -A
