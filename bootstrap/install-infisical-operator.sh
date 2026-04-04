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
helm repo add infisical-charts https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/
helm repo update
kubectl create namespace infisical-operator
helm install secrets-operator infisical-charts/secrets-operator --namespace infisical-operator
