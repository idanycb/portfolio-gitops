#!/bin/bash
# scripts/bootstrap-flux.sh: Post-Cloud-Init automation to bootstrap Flux over SSH

# Set up absolute paths correctly
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

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
echo "Extracting Flux SSH Key from Infisical-provisioned secret..."
NAMESPACE="flux-system"
SECRET_NAME="flux-system"

# Wait for the secret to appear (if the operator is still syncing)
until kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" &> /dev/null; do
  echo "Waiting for secret $SECRET_NAME in namespace $NAMESPACE..."
  sleep 5
done

# Save the private key to a temporary file
TEMP_KEY=$(mktemp)
kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" -o jsonpath='{.data.identity}' | base64 -d > "$TEMP_KEY"
chmod 600 "$TEMP_KEY"

# 4. Run Flux Bootstrap (SSH Method)
echo "Bootstrapping Flux over SSH..."
flux bootstrap git \
  --url=ssh://git@github.com/idanycb/portfolio-gitops \
  --branch=main \
  --path=clusters/prod \
  --secret-name="$SECRET_NAME" \
  --private-key-file="$TEMP_KEY"

# 5. Cleanup
echo "Cleaning up temporary SSH key..."
shred -u "$TEMP_KEY"

echo "------------------------------------------------------------"
echo "Flux Bootstrap Complete! Check your GitHub repository for the clusters/prod directory."
echo "------------------------------------------------------------"
