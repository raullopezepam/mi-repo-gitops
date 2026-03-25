# Secrets Management: ESO + HashiCorp Vault

## Por qué este patrón

El objetivo era poder **modificar un secreto de forma sencilla** sin necesidad de desencriptar/re-encriptar manualmente (workflow tedioso con SealedSecrets). Con ESO + Vault:

- Los secretos **nunca están en git** (ni cifrados)
- Para rotar un valor: un comando o un clic en la UI de Vault
- ESO propaga el cambio al cluster automáticamente (cada `refreshInterval`)
- El mismo patrón que usa EPAM en clientes con AWS Secrets Manager / Azure Key Vault

---

## Arquitectura

```
git (solo referencias, sin datos sensibles)
  resources/apps/keycloak/secrets/external-secret.yaml
  manifests/infrastructure/vault/cluster-secret-store.yaml
          │
          ▼
     ArgoCD sync
          │
          ▼
  ExternalSecret CR   ──────────────────────────────►  HashiCorp Vault
  (en cluster)            ESO hace la petición           secret/keycloak
          │               con K8s auth                   (valores reales)
          ▼
  Secret keycloak-helm-secrets
  (creado y actualizado por ESO)
          │
          ▼
     Keycloak lo consume
```

### Componentes

| Componente | Namespace | Instalación |
|---|---|---|
| HashiCorp Vault | `vault` | `helm install vault hashicorp/vault` |
| External Secrets Operator | `external-secrets` | `helm install external-secrets external-secrets/external-secrets` |
| ClusterSecretStore | cluster-scoped | `manifests/infrastructure/vault/cluster-secret-store.yaml` |
| ExternalSecret (keycloak) | `keycloak` | `resources/apps/keycloak/secrets/external-secret.yaml` |

---

## Bootstrap desde cero

Cuando se recrea el cluster hay que reinstalar Vault y ESO antes de que ArgoCD sincronice Keycloak, porque el `ExternalSecret` necesita el `ClusterSecretStore` para poder crear el `Secret`.

### 1. Añadir repos Helm

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
```

### 2. Instalar Vault en modo dev

```bash
kubectl create namespace vault
helm install vault hashicorp/vault \
  --namespace vault \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=root" \
  --set "ui.enabled=true" \
  --set "injector.enabled=false"

kubectl wait --for=condition=Ready pod/vault-0 -n vault --timeout=90s
```

> **Nota:** El modo dev usa almacenamiento en memoria. Los secretos se pierden si el pod se reinicia. Para producción usar `server.ha.enabled=true` con almacenamiento persistente.

### 3. Instalar External Secrets Operator

```bash
kubectl create namespace external-secrets
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --set installCRDs=true

kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=external-secrets \
  -n external-secrets --timeout=90s
```

### 4. Configurar Kubernetes auth en Vault

```bash
# Habilitar el método de autenticación
kubectl exec -n vault vault-0 -- vault auth enable kubernetes

# Configurar con la URL del API server (se resuelve automáticamente dentro del pod)
kubectl exec -n vault vault-0 -- sh -c '
vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"
'

# Crear policy que permite a ESO leer secretos
kubectl exec -n vault vault-0 -- sh -c '
cat > /tmp/eso-policy.hcl << EOF
path "secret/data/*" {
  capabilities = ["read"]
}
EOF
vault policy write eso-policy /tmp/eso-policy.hcl
'

# Crear rol que vincula el service account de ESO con la policy
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/eso-role \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-policy \
  ttl=24h
```

### 5. Aplicar el ClusterSecretStore

```bash
kubectl apply -f manifests/infrastructure/vault/cluster-secret-store.yaml

# Verificar que conecta correctamente con Vault
kubectl get clustersecretstore vault-cluster-store
# Debe mostrar: STATUS: Valid  READY: True
```

### 6. Meter los secretos de Keycloak en Vault

```bash
kubectl exec -n vault vault-0 -- vault kv put secret/keycloak \
  admin-password=<valor> \
  password=<valor> \
  postgres-password=<valor>
```

### 7. Sincronizar ArgoCD

Una vez completados los pasos anteriores, ArgoCD puede sincronizar `keycloak-app` y el `ExternalSecret` creará el `Secret` automáticamente.

---

## Operaciones del día a día

### Rotar un secreto (forma 1: CLI)

```bash
# Cambiar un valor concreto sin tocar el resto
kubectl exec -n vault vault-0 -- vault kv patch secret/keycloak \
  admin-password=nuevo-valor

# ESO propaga el cambio en el próximo refreshInterval (actualmente: 1m)
```

### Rotar un secreto (forma 2: UI de Vault)

```bash
# Exponer la UI de Vault
kubectl patch svc vault-ui -n vault -p '{"spec": {"type": "NodePort"}}'
minikube service vault-ui -n vault --url
```

1. Abrir la URL en el navegador
2. Login → Method: `Token` → Token: `root`
3. Secrets Engines → `secret` → `keycloak`
4. **Create new version** → editar el valor → **Save**
5. En menos de 1 minuto ESO actualiza el Secret en Kubernetes

### Ver el valor actual de un secreto

```bash
# En Vault (fuente de verdad)
kubectl exec -n vault vault-0 -- vault kv get secret/keycloak

# En Kubernetes (lo que tiene el cluster ahora mismo)
kubectl get secret keycloak-helm-secrets -n keycloak -o jsonpath='{.data}' | \
  python3 -c "import sys,json,base64; [print(f'{k}={base64.b64decode(v).decode()}') for k,v in json.load(sys.stdin).items()]"
```

### Ver historial de versiones de un secreto

```bash
kubectl exec -n vault vault-0 -- vault kv metadata get secret/keycloak
```

### Añadir un secreto nuevo para otra app

1. Guardar los valores en Vault:
```bash
kubectl exec -n vault vault-0 -- vault kv put secret/<app> \
  clave1=valor1 \
  clave2=valor2
```

2. Crear el `ExternalSecret` en `resources/apps/<app>/secrets/external-secret.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <app>-secrets
  namespace: <app>
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: vault-cluster-store
    kind: ClusterSecretStore
  target:
    name: <app>-secrets
    creationPolicy: Owner
  data:
    - secretKey: clave1
      remoteRef:
        key: secret/<app>
        property: clave1
```

3. Referenciar el path en la fuente de ArgoCD Application y hacer `git push`.

### Verificar estado de sincronización de ESO

```bash
kubectl get externalsecret -A
# STATUS: SecretSynced  READY: True  → todo correcto
```

---

## Estructura de ficheros relevantes

```
manifests/infrastructure/
  vault/
    cluster-secret-store.yaml     # ClusterSecretStore apuntando a Vault

resources/apps/
  keycloak/
    secrets/
      external-secret.yaml        # ExternalSecret — lo gestiona ArgoCD
    values.yaml                   # auth.existingSecret: keycloak-helm-secrets
```

---

## Comparativa con el enfoque anterior (SealedSecrets)

| | SealedSecrets (anterior) | ESO + Vault (actual) |
|---|---|---|
| Secretos en git | Sí (cifrados, cluster-bound) | No |
| Para rotar | decrypt → editar → kubeseal → commit → push | 1 comando o UI |
| Necesita cluster para cifrar | Sí | No |
| Rotación automática | No | Sí (refreshInterval) |
| Equivalente en producción | Aceptable | AWS SM / Azure KV / GCP SM |
