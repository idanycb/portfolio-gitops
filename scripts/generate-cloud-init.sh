#!/bin/bash
# Builder script to generate the final cloud-init.yaml from separate files

# Set up absolute paths correctly
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

IDENTITY_ID=${1:-"431882cb-5d6c-4655-8db7-c3089d8d7dc8"}

cat <<EOF > "$ROOT_DIR/bootstrap/cloud-init.yaml"
#cloud-config
package_update: true
package_upgrade: true

packages:
  - curl
  - git
  - apt-transport-https
  - ca-certificates

write_files:
  - path: /usr/local/bin/install-infisical-operator.sh
    permissions: '0755'
    content: |
$(sed '      s/^/      /' "$ROOT_DIR/bootstrap/install-infisical-operator.sh")

  - path: /var/lib/rancher/k3s/server/manifests/infisical-auth-setup.yaml
    content: |
$(sed '      s/^/      /' "$ROOT_DIR/bootstrap/infisical-auth-setup.yaml")

  - path: /var/lib/rancher/k3s/server/manifests/flux-secret-sync.yaml
    content: |
$(sed "      s/YOUR_IDENTITY_ID_HERE/$IDENTITY_ID/" "$ROOT_DIR/bootstrap/flux-secret-sync.yaml" | sed '      s/^/      /')

runcmd:
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
  - /usr/local/bin/install-infisical-operator.sh
EOF

echo "Successfully generated $ROOT_DIR/bootstrap/cloud-init.yaml with Identity ID: $IDENTITY_ID"
