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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "Adding Prometheus Community Helm repo..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

log "Installing kube-prometheus-stack..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.env.GF_SERVER_ROOT_URL="http://%(domain)s/grafana" \
  --set grafana.env.GF_SERVER_SERVE_FROM_SUB_PATH="true" \
  --set grafana.adminPassword="pala3105" \
  --set prometheus-node-exporter.resources.requests.cpu=50m \
  --set prometheus-node-exporter.resources.requests.memory=64Mi \
  --set kube-state-metrics.resources.requests.cpu=50m \
  --set kube-state-metrics.resources.requests.memory=64Mi \
  --set prometheus.prometheusSpec.resources.requests.cpu=100m \
  --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
  --set grafana.resources.requests.cpu=50m \
  --set grafana.resources.requests.memory=128Mi \
  --set alertmanager.alertmanagerSpec.resources.requests.cpu=10m \
  --set alertmanager.alertmanagerSpec.resources.requests.memory=32Mi \
  --wait \
  --timeout 5m

log "Applying Grafana ingress..."
kubectl apply -f "$SCRIPT_DIR/grafana-ingress.yaml" -n monitoring
kubectl apply -f "$SCRIPT_DIR/grafana-network-policy.yaml" -n monitoring

log "Observability stack installation complete!"