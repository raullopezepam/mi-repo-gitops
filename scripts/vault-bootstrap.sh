#!/bin/bash
# vault-bootstrap.sh — configura Vault y recarga secretos tras recrear el cluster
# Uso: ./scripts/vault-bootstrap.sh
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGE_KEY="$REPO_ROOT/.sops/age/keys.txt"
SECRETS_FILE="$REPO_ROOT/secrets/all.enc.yaml"

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
echo "==> Cargando secretos en Vault desde $SECRETS_FILE..."

SOPS_AGE_KEY_FILE="$AGE_KEY" sops -d "$SECRETS_FILE" | \
  python3 "$REPO_ROOT/scripts/load-secrets-to-vault.py"

# ── 3. Recrear ClusterSecretStore ───────────────────────────────────────────
echo ""
echo "==> Reconectando ClusterSecretStore con Vault..."
kubectl delete clustersecretstore vault-cluster-store --ignore-not-found
kubectl apply -f "$REPO_ROOT/manifests/infrastructure/vault/cluster-secret-store.yaml"
kubectl wait --for=jsonpath='{.status.conditions[0].status}'=True \
  clustersecretstore/vault-cluster-store --timeout=30s

# ── 4. Forzar re-sync de ExternalSecrets ────────────────────────────────────
echo ""
echo "==> Forzando re-sync de ExternalSecrets..."
kubectl get externalsecret -A --no-headers | while read ns name _rest; do
  kubectl annotate externalsecret "$name" -n "$ns" \
    force-sync=$(date +%s) --overwrite 2>/dev/null
done

echo ""
echo "==> Estado final:"
kubectl get clustersecretstore vault-cluster-store
echo ""
kubectl get externalsecret -A
