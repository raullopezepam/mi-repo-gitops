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

| Componente | Namespace | Gestionado por |
|---|---|---|
| HashiCorp Vault | `vault` | ArgoCD (wave 1) |
| External Secrets Operator | `external-secrets` | ArgoCD (wave 2) |
| ClusterSecretStore | cluster-scoped | ArgoCD (wave 3) |
| ExternalSecret (keycloak) | `keycloak` | ArgoCD (wave 4) |

### Sync waves (orden de despliegue)

ArgoCD despliega los componentes en orden usando `argocd.argoproj.io/sync-wave`:

```
Wave 1 → vault            espera a que Vault pod esté Ready
Wave 2 → external-secrets espera a que ESO pods estén Ready
Wave 3 → vault-config     aplica ClusterSecretStore (necesita Vault + ESO)
Wave 4 → keycloak-app     aplica ExternalSecret + Helm chart
```

---

## Bootstrap desde cero

Cuando se recrea el cluster, ArgoCD gestiona la instalación de Vault y ESO automáticamente en el orden correcto. Solo hay un paso manual: cargar los secretos en Vault.

### 1. Bootstrap de ArgoCD

```bash
kubectl apply -f revissions/apps-revission.yaml
```

ArgoCD arranca y sincroniza automáticamente en orden:
- **Wave 1:** instala Vault (Helm chart) y espera a que esté Ready
- **Wave 2:** instala ESO (Helm chart + CRDs) y espera a que esté Ready
- **Wave 3:** aplica el ClusterSecretStore y verifica conexión con Vault
- **Wave 4:** despliega Keycloak con el ExternalSecret

### 2. Cargar secretos en Vault (único paso manual)

```bash
./scripts/vault-bootstrap.sh
```

Este script:
- Configura Kubernetes auth en Vault (policy + rol para ESO)
- Descifra `secrets/all.enc.yaml` con SOPS y carga los valores en Vault
- Reconecta el ClusterSecretStore
- Fuerza el re-sync de todos los ExternalSecrets

> Requiere la clave AGE en `.sops/age/keys.txt`. Es el único paso que no puede automatizarse porque la clave privada no se commitea en git.

> **Vault en modo dev:** los secretos se pierden si el pod de Vault se reinicia. Ejecutar `./scripts/vault-bootstrap.sh` de nuevo para recargarlos.

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
