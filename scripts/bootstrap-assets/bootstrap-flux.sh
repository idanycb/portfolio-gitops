#!/bin/bash
# scripts/bootstrap-flux.sh: Post-Cloud-Init automation to bootstrap Flux over SSH

set -euo pipefail

# Set up absolute paths correctly
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
POSTCLEANUP_SCRIPT="$SCRIPT_DIR/bootstrap-postcleanup.sh"

# 1. Ensure KUBECONFIG is set (if running on node)
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

if [ ! -f "$KUBECONFIG" ]; then
  echo "Error: Kubeconfig not found at $KUBECONFIG. Are you on the OCI node?"
  exit 1
fi

# 2. Install Flux CLI (if not present)
if ! command -v flux &> /dev/null; then
  echo "Installing Flux CLI..."
  curl -s https://fluxcd.io/install.sh | sudo bash
fi

# 3. Extract the Flux SSH Key from Infisical Secret
NAMESPACE="flux-system"
SECRET_NAME="flux-ssh-key"

echo "Ensuring namespace $NAMESPACE exists..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Wait for the secret to appear (if the operator is still syncing)
until kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" &> /dev/null; do
  echo "Waiting for secret $SECRET_NAME in namespace $NAMESPACE..."
  sleep 5
done

echo "Extracting Flux SSH Key from Infisical-provisioned secret..."
# Save the private key to a temporary file
TEMP_KEY=$(mktemp)
kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" -o jsonpath='{.data.identity}' | base64 -d > "$TEMP_KEY"
chmod 600 "$TEMP_KEY"

cleanup_temp_key() {
  if [ -n "${TEMP_KEY:-}" ] && [ -f "$TEMP_KEY" ]; then
    shred -u "$TEMP_KEY"
  fi
}

trap cleanup_temp_key EXIT

# Add Gateway API CRDs to K3s manifests for Flux to manage
curl -LO https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml
sudo mv standard-install.yaml /var/lib/rancher/k3s/server/manifests/gateway-api-crds.yaml

# 4. Run Flux Bootstrap (SSH Method)
echo "Bootstrapping Flux over SSH..."
flux bootstrap git \
  --url=ssh://git@github.com/idanycb/portfolio-gitops \
  --branch=main \
  --path=clusters/prod \
  --secret-name="$SECRET_NAME" \
  --private-key-file="$TEMP_KEY" \
  --components-extra=image-reflector-controller,image-automation-controller

echo
echo "Running post-bootstrap cleanup..."
if [ -f "$POSTCLEANUP_SCRIPT" ]; then
  bash "$POSTCLEANUP_SCRIPT"
else
  echo "Warning: postcleanup script not found at $POSTCLEANUP_SCRIPT" >&2
fi

# 5. Cleanup temp key via trap
echo "Cleaning up temporary SSH key..."

echo "------------------------------------------------------------"
echo "Flux Bootstrap Complete! Check your GitHub repository for the clusters/prod directory."
echo "------------------------------------------------------------"
