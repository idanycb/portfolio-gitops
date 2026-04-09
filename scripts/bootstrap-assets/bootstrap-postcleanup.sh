#!/bin/bash

set -e

MANIFEST_DIR="/var/lib/rancher/k3s/server/manifests"
RUNTIME_SCRIPT_DIR="/opt/bootstrap-runtime"

echo
echo "🧹 Starting cleanup of K3s static manifests..."

# System components to keep
SYSTEM_COMPONENTS=(
  "ccm.yaml"
  "coredns.yaml"
  "local-storage.yaml"
  "metrics-server"
  "rolebindings.yaml"
  "runtimes.yaml"
)

# Custom bootstrap components to remove
CUSTOM_COMPONENTS=(
  "infisical-auth-setup.yaml"
  "infisical-secret-sync.yaml"
  "traefik.yaml"
)

# Remove custom components
for file in "${CUSTOM_COMPONENTS[@]}"; do
  if [ -f "$MANIFEST_DIR/$file" ]; then
    echo "🗑 Removing $file"
    sudo rm -f "$MANIFEST_DIR/$file"
  else
    echo "✔ $file already removed"
  fi
done

echo
echo "✨ Handover complete. Flux now fully owns Traefik and Infisical."

echo
echo "🗑 Removing runtime bootstrap scripts..."
if [ -d "$RUNTIME_SCRIPT_DIR" ]; then
  sudo rm -rf "$RUNTIME_SCRIPT_DIR"
  echo "✔ Removed $RUNTIME_SCRIPT_DIR"
else
  echo "✔ $RUNTIME_SCRIPT_DIR already removed"
fi

echo
echo "Cleanup complete. K3s static manifests cleaned up, and runtime scripts removed."