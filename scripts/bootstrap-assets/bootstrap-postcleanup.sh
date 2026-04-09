#!/bin/bash

set -e

MANIFEST_DIR="/var/lib/rancher/k3s/server/manifests"
RUNTIME_SCRIPT_DIR="/opt/bootstrap-runtime"

echo "🔍 Waiting for Flux-managed Traefik to take over..."
echo

# Wait for Flux HelmRelease to exist
echo "⏳ Waiting for HelmRelease 'traefik' to appear..."
until kubectl get helmrelease -A 2>/dev/null | grep -qi "traefik"; do
  sleep 5
done
echo "✔ Flux HelmRelease for Traefik detected."

# Wait for Traefik Deployment to be healthy
echo "⏳ Waiting for Traefik Deployment to become Ready..."
until kubectl -n traefik get deploy traefik 2>/dev/null | grep -q "1/1"; do
  sleep 5
done
echo "✔ Flux-managed Traefik Deployment is Ready."

# Wait for K3s Traefik to disappear (K3s version uses namespace 'kube-system')
echo "⏳ Checking for K3s-managed Traefik..."
if kubectl -n kube-system get deploy traefik 2>/dev/null; then
  echo "⚠ K3s Traefik still exists — waiting for Flux to override it..."
  until ! kubectl -n kube-system get deploy traefik 2>/dev/null; do
    sleep 5
  done
fi
echo "✔ K3s Traefik is no longer active."

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