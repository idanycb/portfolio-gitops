# Portfolio GitOps Bootstrap Guide

## What this repository does

This repository bootstraps a single-node K3s cluster on OCI ARM using cloud-init, then hands cluster state management to Flux.

Main goals:
- Provision the node with zero-touch cloud-init.
- Install Infisical operator so the Flux SSH key is pulled from Infisical at runtime.
- Bootstrap Flux against this repository path clusters/prod.
- Keep infrastructure and application state managed declaratively from Git.

## Network architecture

The node has no public IP. All inbound traffic reaches it through a network load balancer that only accepts known sources.

```
client → Cloudflare proxy → OCI Network Load Balancer (public IP) → K3s instance (private subnet) → Traefik
Infisical Cloud → api.danycb.com:6443 (DNS only) → Network Load Balancer → Kubernetes API
```

- K3s instance: private subnet, no public IP. Outbound access (GitHub, GHCR, Infisical, package mirrors) goes through the VCN's NAT gateway.
- Network Load Balancer: public subnet, reserved public IP, TCP pass-through to the instance. Its network security group allows:
  - 80 and 443 from Cloudflare's IPv4 ranges only (https://www.cloudflare.com/ips-v4)
  - 6443 from Infisical's egress IPs only (Kubernetes Auth token review)
- Cloudflare DNS: `danycb.com` and `*.danycb.com` are proxied. `api.danycb.com` is DNS only, because Cloudflare can't proxy port 6443 and Infisical must verify the API server's own certificate.
- SSH: through OCI Bastion only. No SSH rules are open on the load balancer or the public subnet.
- In the cluster, Traefik is the single entry point (Gateway API). App namespaces use default-deny ingress NetworkPolicies.

Cloudflare occasionally changes its IP ranges. When it does, update the load balancer's security group rules to match.

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
1. Install base packages and open host firewall ports 80, 443, 6443 (iptables). External exposure is controlled by the load balancer's security group, not the host.
2. Install K3s with tls-san api.danycb.com (bundled Traefik disabled).
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

Run on the OCI node through an OCI Bastion session (or any machine with kubectl access to this cluster):

Kubernetes API URL for Infisical: `https://api.danycb.com:6443`

On the node, `kubectl config view` reports `https://127.0.0.1:6443`, which only works locally. Infisical Cloud must use the public DNS name, which the API server certificate covers through `--tls-san`.

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

- Create an OCI ARM instance (Ubuntu) in the private subnet, with no public IP.
- Paste bootstrap/cloud-init.yaml as user-data.
- Add the instance as the backend of the Network Load Balancer, which holds the reserved public IP.
- Make sure the load balancer's security group allows 80/443 from Cloudflare's ranges and 6443 from Infisical's egress IPs only (see Network architecture).
- Point Cloudflare DNS at the load balancer's public IP: proxy `danycb.com` and `*.danycb.com`, and set `api.danycb.com` to DNS only.

### 3) Wait for first boot automation

Cloud-init performs K3s installation, Infisical setup, Flux bootstrap, and post-bootstrap cleanup automatically.

### 4) Verify cluster and GitOps state

Run on the node (through OCI Bastion):
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
