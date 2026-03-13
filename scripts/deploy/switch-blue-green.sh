#!/bin/bash
# Usage: ./switch-blue-green.sh <color>

set -e

COLOR="$1"
if [[ "$COLOR" != "blue" && "$COLOR" != "green" ]]; then
  echo "Usage: $0 <blue|green>"
  exit 1
fi

echo "All deployments switched to $COLOR."
NAMESPACE=wiseling
DEPLOY_PATH="../../kubernetes-manifests/deployments/${COLOR}-deployments"

echo "Applying manifests from $DEPLOY_PATH..."
kubectl apply -f "$DEPLOY_PATH/auth-service/"
kubectl apply -f "$DEPLOY_PATH/conversion-service/"
kubectl apply -f "$DEPLOY_PATH/wallet-service/"
kubectl apply -f "$DEPLOY_PATH/withdrawal-service/"
kubectl apply -f "$DEPLOY_PATH/workers/"
kubectl apply -f "$DEPLOY_PATH/frontend-service/"

echo "All $COLOR deployments applied."
