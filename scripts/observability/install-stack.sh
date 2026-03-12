#!/bin/bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.env.GF_SERVER_ROOT_URL="http://%(domain)s/grafana" \
  --set grafana.env.GF_SERVER_SERVE_FROM_SUB_PATH="true" \
  --set grafana.adminPassword="pala3105" \
  --wait

kubectl apply -f grafana-ingress.yaml -n monitoring