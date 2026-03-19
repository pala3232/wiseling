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
  --values "$SCRIPT_DIR/values.yaml" \
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

log "Adding Chaos Mesh Helm repo..."
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update

log "Installing Chaos Mesh..."
helm rollback chaos-mesh -n chaos-mesh 2>/dev/null || true
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-mesh \
  --create-namespace \
  --version 2.6.3 \
  --set chaosDaemon.resources.requests.cpu=50m \
  --set chaosDaemon.resources.requests.memory=64Mi \
  --wait \
  --timeout 5m

log "Observability stack and Chaos Mesh installation complete!"