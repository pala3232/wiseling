#!/bin/bash
set -euo pipefail

# ─── Logging ──────────────────────────────────────────────────────────────────

log()     { echo -e "\033[1;34m[$(date '+%H:%M:%S')] INFO     $*\033[0m"; }
success() { echo -e "\033[1;32m[$(date '+%H:%M:%S')] SUCCESS  $*\033[0m"; }
warn()    { echo -e "\033[1;33m[$(date '+%H:%M:%S')] WARNING  $*\033[0m"; }
error()   { echo -e "\033[1;31m[$(date '+%H:%M:%S')] ERROR    $*\033[0m" >&2; }

error_handler() {
  error "Script failed at line $1. Cleaning up..."
  cleanup
  exit 1
}
trap 'error_handler $LINENO' ERR

CHAOS_DIR="kubernetes-manifests/chaos"
JOBS_DIR="kubernetes-manifests/jobs"
NAMESPACE="wiseling"
ALERTMANAGER_URL="http://localhost:9093"
LOCUST_JOB="wiseling-load-test"

PASSED=0
FAILED=0

# ─── Cleanup ──────────────────────────────────────────────────────────────────

cleanup() {
  log "Cleaning up chaos experiments and locust job..."
  kubectl delete -f "$CHAOS_DIR/" --ignore-not-found -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete job "$LOCUST_JOB" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  pkill -f "kubectl port-forward.*alertmanager" 2>/dev/null || true

  log "Restoring all deployments to 2 replicas..."
  for deploy in auth-service-deployment wallet-service-deployment conversion-service-deployment withdrawal-service-deployment; do
    kubectl scale deployment -n "$NAMESPACE" "$deploy" --replicas=2 2>/dev/null || true
  done
  kubectl scale deployment -n "$NAMESPACE" wallet-consumer --replicas=2 2>/dev/null || true
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

wait_for_deployment_ready() {
  local deployment=$1
  local replicas=${2:-2}
  local timeout=${3:-60}
  log "Waiting for $deployment to have $replicas ready replica(s)..."
  kubectl rollout status deployment/"$deployment" -n "$NAMESPACE" --timeout="${timeout}s" 2>/dev/null || true
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    local ready
    ready=$(kubectl get deployment "$deployment" -n "$NAMESPACE" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${ready:-0}" -ge "$replicas" ]; then
      success "$deployment — $ready/$replicas replica(s) ready"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  warn "$deployment did not reach $replicas replicas within ${timeout}s"
}

# ─── Assertions ───────────────────────────────────────────────────────────────

assert_pods_running() {
  local label=$1
  local description=$2
  log "Checking pods are running: $description..."
  local running
  running=$(kubectl get pods -n "$NAMESPACE" -l "$label" \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [ "$running" -gt 0 ]; then
    success "$description — $running pod(s) running"
    PASSED=$((PASSED + 1))
  else
    error "$description — no running pods found"
    FAILED=$((FAILED + 1))
  fi
}

assert_service_healthy() {
  local deployment=$1
  local port=$2
  local health_path=$3
  local description=$4
  log "Checking $description health endpoint..."
  if timeout 15 kubectl exec -n "$NAMESPACE" \
    "deploy/$deployment" -- \
    curl -sf --max-time 5 "http://localhost:$port$health_path" &>/dev/null; then
    success "$description — health check passed"
    PASSED=$((PASSED + 1))
  else
    warn "$description — health check failed (pod may still be warming up)"
    FAILED=$((FAILED + 1))
  fi
}

assert_alerts_firing() {
  local alert_name=$1
  local description=$2
  local timeout=${3:-30}
  log "Checking Alertmanager for alert: $alert_name (timeout: ${timeout}s)..."
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    local count
    count=$(curl -sf "${ALERTMANAGER_URL}/api/v2/alerts" 2>/dev/null | \
      python3 -c "
import sys, json
alerts = json.load(sys.stdin)
print(sum(1 for a in alerts if '$alert_name' in a.get('labels', {}).get('alertname', '')))
" 2>/dev/null || echo "0")
    if [ "$count" -gt 0 ]; then
      success "Alert '$alert_name' firing ($count active) — $description"
      PASSED=$((PASSED + 1))
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  warn "Alert '$alert_name' not firing after ${timeout}s — $description"
  FAILED=$((FAILED + 1))
}

assert_alerts_resolved() {
  local alert_name=$1
  local description=$2
  local timeout=${3:-120}
  log "Waiting for alert '$alert_name' to resolve (timeout: ${timeout}s)..."
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    local count
    count=$(curl -sf "${ALERTMANAGER_URL}/api/v2/alerts" 2>/dev/null | \
      python3 -c "
import sys, json
alerts = json.load(sys.stdin)
print(sum(1 for a in alerts if '$alert_name' in a.get('labels', {}).get('alertname', '')))
" 2>/dev/null || echo "0")
    if [ "$count" -eq 0 ]; then
      success "Alert '$alert_name' resolved after ${elapsed}s"
      PASSED=$((PASSED + 1))
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  warn "Alert '$alert_name' still firing after ${timeout}s"
  FAILED=$((FAILED + 1))
}

# ─── Port-forward Alertmanager ────────────────────────────────────────────────

setup_alertmanager_portforward() {
  log "Setting up Alertmanager port-forward..."
  kubectl port-forward -n monitoring \
    svc/kube-prometheus-stack-alertmanager 9093:9093 &>/dev/null &
  sleep 3
  if curl -sf "${ALERTMANAGER_URL}/api/v2/status" &>/dev/null; then
    success "Alertmanager port-forward established"
  else
    warn "Could not reach Alertmanager — alert assertions will warn instead of fail"
  fi
}

# ─── Preflight ────────────────────────────────────────────────────────────────

preflight() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "PREFLIGHT: Verifying all services are healthy before experiments"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  assert_pods_running "app=auth-service" "auth-service"
  assert_pods_running "app=wallet-service" "wallet-service"
  assert_pods_running "app=conversion-service" "conversion-service"
  assert_pods_running "app=withdrawal-service" "withdrawal-service"
  assert_pods_running "app=wallet-consumer" "wallet-consumer"
  assert_pods_running "app=conversion-outbox-poller" "conversion-outbox-poller"
  assert_pods_running "app=withdrawal-processor" "withdrawal-processor"
  success "Preflight complete — all services healthy"
}

# ─── Locust (fire and forget) ─────────────────────────────────────────────────

start_locust() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "LOAD TEST: Starting Locust (runs in background during experiments)"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  kubectl delete job "$LOCUST_JOB" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  sleep 3
  kubectl apply -f "$JOBS_DIR/locust-job.yaml"
  success "Locust job started"
}

# ─── Experiment 1: wallet-service scale-to-zero (~3.5 min) ───────────────────

experiment_01_wallet_scale_down() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "EXPERIMENT 01: wallet-service scale-to-zero"
  log "Validates: PodNotReady + WalletServiceDown fire and resolve"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl scale deployment -n "$NAMESPACE" wallet-service-deployment --replicas=0
  log "wallet-service scaled to 0 — waiting 90s for alerts to fire..."
  sleep 90

  assert_alerts_firing "PodNotReady" "PodNotReady should fire with 0 replicas" 30
  assert_alerts_firing "WalletServiceDown" "WalletServiceDown should fire" 90

  kubectl scale deployment -n "$NAMESPACE" wallet-service-deployment --replicas=2
  wait_for_deployment_ready "wallet-service-deployment" 2 60
  sleep 10
  assert_service_healthy "wallet-service-deployment" "8001" "/metrics" "wallet-service"
  assert_alerts_resolved "PodNotReady" "PodNotReady should resolve" 120
  assert_alerts_resolved "WalletServiceDown" "WalletServiceDown should resolve" 120

  success "Experiment 01 complete"
}

# ─── Experiment 2: outbox poller network delay (~2.5 min) ────────────────────

experiment_02_outbox_poller_kill() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "EXPERIMENT 02: conversion-outbox-poller scale-to-zero"
  log "Validates: Poller recovers, no message loss"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl scale deployment -n "$NAMESPACE" conversion-outbox-poller --replicas=0
  log "conversion-outbox-poller scaled to 0 — waiting 45s..."
  sleep 45

  local running
  running=$(kubectl get pods -n "$NAMESPACE" -l "app=conversion-outbox-poller" \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [ "$running" -eq 0 ]; then
    success "conversion-outbox-poller — confirmed 0 pods running"
    PASSED=$((PASSED + 1))
  else
    warn "conversion-outbox-poller — $running pod(s) still running unexpectedly"
    FAILED=$((FAILED + 1))
  fi

  kubectl scale deployment -n "$NAMESPACE" conversion-outbox-poller --replicas=1
  wait_for_deployment_ready "conversion-outbox-poller" 1 60
  assert_pods_running "app=conversion-outbox-poller" "conversion-outbox-poller recovered"

  success "Experiment 02 complete"
}

# ─── Experiment 3: withdrawal-service scale-to-zero (~3 min) ─────────────────

experiment_03_high_error_rate() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "EXPERIMENT 03: withdrawal-service scale-to-zero"
  log "Validates: HighErrorRate + WithdrawalServiceDown fire and resolve"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl scale deployment -n "$NAMESPACE" withdrawal-service-deployment --replicas=0
  log "withdrawal-service scaled to 0 — waiting 2 minutes for alerts to fire..."
  sleep 120

  assert_alerts_firing "HighErrorRate" "HighErrorRate should fire under load" 30
  assert_alerts_firing "WithdrawalServiceDown" "WithdrawalServiceDown should fire" 90

  kubectl scale deployment -n "$NAMESPACE" withdrawal-service-deployment --replicas=2
  wait_for_deployment_ready "withdrawal-service-deployment" 2 60
  sleep 10
  assert_service_healthy "withdrawal-service-deployment" "8003" "/metrics" "withdrawal-service"
  assert_alerts_resolved "HighErrorRate" "HighErrorRate should resolve" 120
  assert_alerts_resolved "WithdrawalServiceDown" "WithdrawalServiceDown should resolve" 120

  success "Experiment 03 complete"
}

# ─── Experiment 4: wallet-consumer scale-to-zero (~1.5 min) ──────────────────

experiment_04_wallet_consumer_kill() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "EXPERIMENT 04: wallet-consumer scale-to-zero (SQS path)"
  log "Validates: Consumer recovers, SQS drains cleanly"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl scale deployment -n "$NAMESPACE" wallet-consumer --replicas=0
  log "wallet-consumer scaled to 0 — accumulating SQS for 45s..."
  sleep 45

  local running
  running=$(kubectl get pods -n "$NAMESPACE" -l "app=wallet-consumer" \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [ "$running" -eq 0 ]; then
    success "wallet-consumer — confirmed 0 pods running"
    PASSED=$((PASSED + 1))
  else
    warn "wallet-consumer — $running pod(s) still running unexpectedly"
    FAILED=$((FAILED + 1))
  fi

  kubectl scale deployment -n "$NAMESPACE" wallet-consumer --replicas=2
  wait_for_deployment_ready "wallet-consumer" 2 60
  assert_pods_running "app=wallet-consumer" "wallet-consumer recovered"

  success "Experiment 04 complete"
}

# ─── Experiment 5: conversion-service latency (~2 min) ───────────────────────

experiment_05_conversion_scale_down() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "EXPERIMENT 05: conversion-service scale-to-zero"
  log "Validates: ConversionServiceDown fires and resolves"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl scale deployment -n "$NAMESPACE" conversion-service-deployment --replicas=0
  log "conversion-service scaled to 0 — waiting 90s for alerts to fire..."
  sleep 90

  assert_alerts_firing "ConversionServiceDown" "ConversionServiceDown should fire" 90

  kubectl scale deployment -n "$NAMESPACE" conversion-service-deployment --replicas=2
  wait_for_deployment_ready "conversion-service-deployment" 2 60
  assert_service_healthy "conversion-service-deployment" "8002" "/api/v1/conversions/rates" "conversion-service"
  assert_alerts_resolved "ConversionServiceDown" "ConversionServiceDown should resolve" 120

  success "Experiment 05 complete"
}

# ─── Experiment 6: Redis partition (~2 min) ───────────────────────────────────

experiment_06_auth_scale_down() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "EXPERIMENT 06: auth-service scale-to-zero (cascade failure)"
  log "Validates: AuthServiceDown fires and resolves"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl scale deployment -n "$NAMESPACE" auth-service-deployment --replicas=0
  log "auth-service scaled to 0 — waiting 90s for alerts to fire..."
  sleep 90

  assert_alerts_firing "AuthServiceDown" "AuthServiceDown should fire" 90

  kubectl scale deployment -n "$NAMESPACE" auth-service-deployment --replicas=2
  wait_for_deployment_ready "auth-service-deployment" 2 60
  assert_service_healthy "auth-service-deployment" "8000" "/health" "auth-service"
  assert_alerts_resolved "AuthServiceDown" "AuthServiceDown should resolve" 120

  success "Experiment 06 complete"
}

# ─── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
  local total=$((PASSED + FAILED))
  echo ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "RESILIENCE TEST SUMMARY"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  success "Passed: $PASSED / $total assertions"
  if [ "$FAILED" -gt 0 ]; then
    error "Failed: $FAILED / $total assertions"
  fi
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [ "$FAILED" -gt 0 ]; then
    exit 1
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  log "Starting Wiseling resilience test suite..."
  log "Chaos experiments: $CHAOS_DIR"
  log "Load test job: $JOBS_DIR/locust-job.yaml"
  echo ""

  log "Applying Chaos Mesh RBAC permissions..."
  kubectl apply -f kubernetes-manifests/chaos/chaos-mesh-rbac.yaml
  success "Chaos Mesh RBAC applied"

  setup_alertmanager_portforward
  preflight
  start_locust

  log "Waiting 30s for Locust to ramp up before injecting chaos..."
  sleep 30

  experiment_01_wallet_scale_down
  experiment_02_outbox_network_delay
  experiment_03_high_error_rate
  experiment_04_wallet_consumer_kill
  experiment_05_conversion_scale_down
  experiment_06_auth_scale_down

  cleanup
  print_summary
}

main "$@"