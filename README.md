# Portfolio GitOps Bootstrap Guide

## What this repository does

This repository bootstraps a single-node K3s cluster on OCI ARM using cloud-init, then hands cluster state management to Flux.

Main goals:
- Provision the node with zero-touch cloud-init.
- Install Infisical operator so the Flux SSH key is pulled from Infisical at runtime.
- Bootstrap Flux against this repository path clusters/prod.
- Keep infrastructure and application state managed declaratively from Git.

## Repository layout

Top-level directories used by runtime bootstrap and GitOps:
- bootstrap
  - Generated cloud-init payload used during OCI instance creation.
- scripts
  - Local helper scripts used to generate the cloud-init payload.
- scripts/bootstrap-assets
  - Source manifests and helper shell script content embedded into cloud-init.
- clusters/prod
  - Flux entry point for production reconciliation.
- infrastructure
  - Core cluster services deployed by Flux (Traefik, cert-manager, Infisical operator resources).

## How files are stored on the server

During first boot, cloud-init writes and executes these files:

Runtime bootstrap scripts:
- /opt/bootstrap-runtime/install-infisical-operator.sh
- /opt/bootstrap-runtime/bootstrap-flux.sh
- /opt/bootstrap-runtime/bootstrap-postcleanup.sh

K3s auto-apply manifests:
- /var/lib/rancher/k3s/server/manifests/infisical-auth-setup.yaml
- /var/lib/rancher/k3s/server/manifests/infisical-secret-sync.yaml

K3s kubeconfig:
- /etc/rancher/k3s/k3s.yaml

Notes:
- Files in /var/lib/rancher/k3s/server/manifests are applied automatically by K3s.
- Runtime scripts are intentionally kept under /opt/bootstrap-runtime.
- After Flux bootstrap succeeds, postcleanup removes bootstrap manifests and deletes /opt/bootstrap-runtime.

## Bootstrap flow on server

Cloud-init execution order:
1. Install base packages and open required firewall ports 80, 443, 6443.
2. Install K3s with tls-san danycb.tech.
3. Run install-infisical-operator.sh.
4. K3s applies infisical-auth-setup.yaml and infisical-secret-sync.yaml from manifests directory.
5. Infisical operator syncs the Flux private key into secret flux-system/flux-system.
6. Run bootstrap-flux.sh.
7. bootstrap-flux.sh installs Flux CLI if missing, reads key from flux-system secret, and runs flux bootstrap git.
8. bootstrap-flux.sh runs bootstrap-postcleanup.sh.
9. bootstrap-postcleanup.sh waits for Flux-managed Traefik takeover, removes bootstrap manifests, and deletes /opt/bootstrap-runtime.

## Configure Infisical Kubernetes Auth (JWT + CA)

After K3s is up, complete the Kubernetes Auth handshake in Infisical Cloud UI.

### 1) Get values from the cluster

Run on the OCI node (or any machine with kubectl access to this cluster):

Get Kubernetes API host URL:

`$ kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}' ; echo`

Get cluster CA certificate (base64):

`$ kubectl get secret infisical-auth-token -n infisical -o jsonpath='{.data.ca\.crt}' | base64 -d ; echo`


Get token reviewer JWT from the service account secret created by cloud-init:

`$ kubectl get secret infisical-auth-token -n infisical -o jsonpath='{.data.token}' | base64 -d ; echo`

Notes:
- The cloud-init manifest creates the service account infisical-auth and secret infisical-auth-token in namespace infisical.
- If the secret is not present yet, wait a minute and retry.

### 2) Add values in Infisical Cloud UI

In Infisical:
1. Open your project and environment (for example, portfolio-gitops / prod).
2. Go to Access Control.
3. Open the machine identity used by this cluster.
4. Open Auth and choose Kubernetes Auth.
5. Fill these fields:
  - Kubernetes API URL
  - Kubernetes CA Certificate
  - Token Reviewer JWT
6. Save the configuration.

### 3) Validate auth/sync is working

Run on cluster:
`$ kubectl get infisicalsecrets -n infisical-secrets`

If flux-system secret exists and contains identity, Infisical auth and sync are correctly configured.

## How to use this repository

### 1) Generate cloud-init payload locally

From repository root:
$ ./scripts/generate-cloud-init.sh

This writes:
- bootstrap/cloud-init.yaml

### 2) Launch OCI instance

- Create an OCI ARM instance (Ubuntu).
- Paste bootstrap/cloud-init.yaml as user-data.
- Attach your reserved public IP and ensure security rules allow 80, 443, 6443.

### 3) Wait for first boot automation

Cloud-init performs K3s installation, Infisical setup, Flux bootstrap, and post-bootstrap cleanup automatically.

### 4) Verify cluster and GitOps state

Run on node:
```
$ kubectl get nodes
$ kubectl get pods -A
$ flux get sources git
$ flux get kustomizations
```

## What Flux is managing

Flux continuously reconciles desired state from this repo:
- clusters/prod defines cluster-level reconciliation targets.
- infrastructure contains core service manifests and Helm resources.
- Future app workloads under apps are reconciled through Flux kustomizations.

## Operational notes

- Do not commit private keys or raw secrets to Git.
- Flux SSH private key is sourced from Infisical and written to a Kubernetes secret.
- bootstrap/cloud-init.yaml is generated output. Regenerate whenever bootstrap script assets change.
- If you update scripts or bootstrap-assets, rerun generate-cloud-init.sh before provisioning a new node.
- Postcleanup waits are timeout-bound by default (15 minutes each). You can tune these with environment variables:
  - HELMRELEASE_WAIT_TIMEOUT_SECONDS
  - DEPLOYMENT_WAIT_TIMEOUT_SECONDS
  - K3S_TRAEFIK_REMOVAL_TIMEOUT_SECONDS
  - WAIT_INTERVAL_SECONDS

## Key files to edit

- scripts/generate-cloud-init.sh
  - Generates the final cloud-init payload.
- scripts/bootstrap-assets/bootstrap-flux.sh
  - Handles Flux bootstrap from the synced Kubernetes secret and invokes postcleanup.
- scripts/bootstrap-assets/bootstrap-postcleanup.sh
  - Waits for Flux Traefik takeover, removes bootstrap manifests, and removes runtime scripts.
- scripts/bootstrap-assets/install-infisical-operator.sh
  - Installs Infisical operator.
- scripts/bootstrap-assets/infisical-auth-setup.yaml
  - Service account and token review setup.
- scripts/bootstrap-assets/infisical-secret-sync.yaml
  - Bootstrap Kubernetes secret for Infisical machine/project IDs.
