# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

GitOps repository for a local Minikube environment managed by the ArgoCD Operator. Uses the **app-of-apps pattern**: a single root ArgoCD Application pointing at `manifests/apps/__overlays` aggregates child Applications via Kustomize.

## Bootstrap (cluster setup from scratch)

```bash
# Install ArgoCD Operator first, then apply the bootstrap manifest:
kubectl apply -f revissions/apps-revission.yaml
```

This creates the `ArgoCD` operator CR and the root `hipstershop-gitops` Application in the `argocd` namespace.

## Repository Structure

```
revissions/apps-revission.yaml     # Bootstrap: ArgoCD operator CR + root Application
manifests/apps/
  __overlays/kustomization.yaml    # Root Kustomize entry point — edit to enable/disable apps
  <app>/base/helmrelease.yaml      # ArgoCD Application CR (NOTE: "helmrelease" is a misnomer — these are Application CRs)
  <app>/lab/kustomization.yaml     # Environment overlay (currently lab only, inherits base)
manifests/infrastructure/
  vault/cluster-secret-store.yaml  # ClusterSecretStore: ESO → Vault connection
resources/apps/
  <app>/values.yaml                # Helm values referenced by ArgoCD multi-source Applications
  keycloak/secrets/
    external-secret.yaml           # ExternalSecret managed by ArgoCD (no sensitive data)
  keycloak/realm-config.json       # Keycloak realm definition (also inlined in values.yaml)
charts/hipster-shop/               # Umbrella Helm chart for hipstershop-demo (11 microservices)
docs/
  secrets-management.md            # ESO + Vault setup and operations guide
.sops/age/keys.txt                 # AGE key pair (present but SOPS is not actively used)
```

## Architecture

### App-of-Apps

`manifests/apps/__overlays/kustomization.yaml` controls which apps are active. To enable an app, uncomment its overlay:

```yaml
resources:
  - ../postgres/lab
  - ../keycloak/lab
  - ../hipstershop-demo/lab
```

Each `lab/kustomization.yaml` references `../base`, which contains the actual ArgoCD `Application` CR.

### Multi-Source ArgoCD Applications

Apps use two sources: one for the Helm chart (Bitnami repo or local `charts/`), and one `ref: values` pointing to this repo for values files. Example pattern in `helmrelease.yaml`:

```yaml
sources:
  - repoURL: https://charts.bitnami.com/bitnami
    chart: keycloak
    targetRevision: 22.1.0
    helm:
      valueFiles:
        - $values/resources/apps/keycloak/values.yaml
  - repoURL: https://github.com/raullopezepam/mi-repo-gitops.git
    targetRevision: main
    ref: values
```

### Applications

| App | Namespace | Chart | Notes |
|-----|-----------|-------|-------|
| keycloak | keycloak | bitnami/keycloak 22.1.0 | Active; uses ESO + Vault for credentials |
| postgres | postgres-ns | bitnami/postgresql 15.5.2 | Commented out; has plaintext creds in values.yaml |
| hipstershop-demo | hipstershop | local `charts/` umbrella | Commented out; 11 Google microservices |

### Secrets

- **Keycloak:** Uses **ESO + HashiCorp Vault**. An `ExternalSecret` CR in `resources/apps/keycloak/secrets/` is managed by ArgoCD. ESO fetches the actual values from Vault (`secret/keycloak`) and creates the `keycloak-helm-secrets` Secret automatically. See `docs/secrets-management.md` for full setup and operations guide.
- **Postgres:** Plaintext credentials in `resources/apps/postgres/values.yaml` — acceptable for local lab only.
- **SOPS/AGE:** Key pair exists at `.sops/age/keys.txt` but SOPS is not actively used (legacy from explored-then-removed KSOPS approach).

> **Important for bootstrap:** Vault and ESO must be installed and configured **before** ArgoCD syncs `keycloak-app`. See `docs/secrets-management.md` for the full bootstrap sequence.

### Keycloak Realm Config

The realm is defined inline in `resources/apps/keycloak/values.yaml` under `keycloakConfigCli.configuration` as `realm-epam.json`. The standalone `resources/apps/keycloak/realm-config.json` is a leftover and may be stale.

## Common Operations

```bash
# Check what's currently active
cat manifests/apps/__overlays/kustomization.yaml

# Preview what Kustomize will render for an overlay
kubectl kustomize manifests/apps/keycloak/lab

# Apply a change (ArgoCD will auto-sync from git, but for immediate local testing):
kubectl apply -k manifests/apps/keycloak/lab

# Rotar un secreto de Keycloak (sin tocar git)
kubectl exec -n vault vault-0 -- vault kv patch secret/keycloak admin-password=nuevo-valor

# Ver valores actuales en Vault
kubectl exec -n vault vault-0 -- vault kv get secret/keycloak

# Exponer la UI de Vault en el navegador
kubectl patch svc vault-ui -n vault -p '{"spec": {"type": "NodePort"}}'
minikube service vault-ui -n vault --url
# Token de acceso: root
```
