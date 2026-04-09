#!/bin/bash
# Wait for K3s to be ready
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
until kubectl get nodes; do
  echo "Waiting for K3s..."
  sleep 5
done

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install Infisical Operator
helm repo add infisical-helm-charts 'https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/'
helm repo update
helm install secrets-operator infisical-helm-charts/secrets-operator \
  --namespace infisical \
  --create-namespace

kubectl create namespace infisical-secrets --dry-run=client -o yaml | kubectl apply -f -