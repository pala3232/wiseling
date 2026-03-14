#!/bin/bash
set -euo pipefail

log() {
  echo -e "\033[1;34m[$(date '+%Y-%m-%d %H:%M:%S')] $*\033[0m"
}

error_handler() {
  echo -e "\033[1;31m[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Script failed at line $1.\033[0m" >&2
  exit 1
}
trap 'error_handler $LINENO' ERR

log "Adding Prometheus Community Helm repo..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

log "Installing kube-prometheus-stack..."
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.env.GF_SERVER_ROOT_URL="http://%(domain)s/grafana" \
  --set grafana.env.GF_SERVER_SERVE_FROM_SUB_PATH="true" \
  --set grafana.adminPassword="pala3105" \
  --wait

log "Applying Grafana ingress..."
kubectl apply -f grafana-ingress.yaml -n monitoring
kubectl apply -f grafana-network-policy.yaml -n monitoring

log "Observability stack installation complete!"