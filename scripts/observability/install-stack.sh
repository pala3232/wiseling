#!/bin/bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.grafana\.ini.server.root_url="http://%(domain)s/grafana" \
  --set grafana.grafana\.ini.server.serve_from_sub_path=true \
  --set grafana.adminPassword="testing1234!"

kubectl rollout status deployment/kube-prometheus-stack-grafana -n monitoring

kubectl apply -f grafana-ingress.yaml -n monitoring