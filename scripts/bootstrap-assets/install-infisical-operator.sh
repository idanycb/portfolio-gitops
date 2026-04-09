#!/bin/bash
# Wait for K3s to be ready
LINE='export KUBECONFIG=/etc/rancher/k3s/k3s.yaml'

# Check if the line already exists
if ! grep -Fxq "$LINE" ~/.bashrc; then
    echo "$LINE" >> ~/.bashrc
    echo "Added KUBECONFIG to ~/.bashrc"
else
    echo "KUBECONFIG already present in ~/.bashrc"
fi

# Reload bashrc for current session
source ~/.bashrc
echo "Reloaded ~/.bashrc"

until kubectl get nodes; do
  echo "Waiting for K3s..."
  sleep 5
done

kubectl create namespace infisical-secrets --dry-run=client -o yaml | kubectl apply -f -

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install Infisical Operator
helm repo add infisical-helm-charts 'https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/'
helm repo update
helm install secrets-operator infisical-helm-charts/secrets-operator \
  --namespace infisical \
  --create-namespace \
  --set controllerManager.serviceAccount.create=false \
  --set controllerManager.serviceAccount.name=infisical-auth
