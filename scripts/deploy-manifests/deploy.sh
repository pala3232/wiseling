#!/bin/bash
set -e
echo "Applying K8s manifests..."
kubectl apply -f ../../kubernetes-manifests/secrets/
kubectl apply -f ../../kubernetes-manifests/configmap/configmap.yaml
kubectl apply -f ../../kubernetes-manifests/secrets/
kubectl apply -f ../../kubernetes-manifests/auth-service/
kubectl apply -f ../../kubernetes-manifests/conversion-service/
kubectl apply -f ../../kubernetes-manifests/wallet-service/
kubectl apply -f ../../kubernetes-manifests/withdrawal-service/
kubectl apply -f ../../kubernetes-manifests/workers/
kubectl apply -f ../../kubernetes-manifests/ingress.yaml
kubectl apply -f ../../kubernetes-manifests/frontend-service/
kubectl apply -f ../../kubernetes-manifests/services

echo "Done!"