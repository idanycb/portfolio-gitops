#!/usr/bin/env bash

# Generate bootstrap/cloud-init.yaml from the source assets under scripts/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ASSET_DIR="$SCRIPT_DIR/bootstrap-assets"
OUTPUT_FILE="$ROOT_DIR/bootstrap/cloud-init.yaml"
RUNTIME_SCRIPT_DIR="/opt/bootstrap-runtime"
INFISICAL_FLUX_FILE="$ROOT_DIR/infrastructure/configs/infisical/infisical-flux.yaml"

required_files=(
  "$ASSET_DIR/install-infisical-operator.sh"
  "$ASSET_DIR/infisical-auth-setup.yaml"
  "$ASSET_DIR/infisical-secret-sync.yaml"
  "$ASSET_DIR/bootstrap-flux.sh"
  "$ASSET_DIR/bootstrap-postcleanup.sh"
)

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "Error: required file not found: $file" >&2
    exit 1
  fi
done

cat <<EOF > "$OUTPUT_FILE"
#cloud-config
package_update: true
package_upgrade: true

packages:
  - curl
  - git
  - apt-transport-https
  - ca-certificates

write_files:
  - path: $RUNTIME_SCRIPT_DIR/install-infisical-operator.sh
    permissions: '0755'
    content: |
$(sed 's/^/      /' "$ASSET_DIR/install-infisical-operator.sh")

  - path: $RUNTIME_SCRIPT_DIR/bootstrap-flux.sh
    permissions: '0755'
    content: |
$(sed 's/^/      /' "$ASSET_DIR/bootstrap-flux.sh")

  - path: $RUNTIME_SCRIPT_DIR/bootstrap-postcleanup.sh
    permissions: '0755'
    content: |
$(sed 's/^/      /' "$ASSET_DIR/bootstrap-postcleanup.sh")

  - path: /var/lib/rancher/k3s/server/manifests/infisical-auth-setup.yaml
    content: |
$(sed 's/^/      /' "$ASSET_DIR/infisical-auth-setup.yaml")

  - path: /var/lib/rancher/k3s/server/manifests/infisical-secret-sync.yaml
    content: |
$(sed 's/^/      /' "$ASSET_DIR/infisical-secret-sync.yaml")

runcmd:
  - mkdir -p "$RUNTIME_SCRIPT_DIR"
  # Configure Firewall (iptables - bypass Oracle default REJECT)
  - iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
  - iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
  - iptables -I INPUT 1 -p tcp --dport 6443 -j ACCEPT
  # Save iptables (requires iptables-persistent)
  - DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
  - netfilter-persistent save
  # Install K3s
  - curl -sfL https://get.k3s.io | sh -s - --tls-san danycb.tech --write-kubeconfig-mode 644
  # Run the Infisical Operator installation script
  - "$RUNTIME_SCRIPT_DIR/install-infisical-operator.sh"
EOF

cp "$ASSET_DIR/infisical-secret-sync.yaml" "$INFISICAL_FLUX_FILE"

echo "Successfully generated $OUTPUT_FILE"
echo "Successfully synced $INFISICAL_FLUX_FILE from infisical-secret-sync.yaml"