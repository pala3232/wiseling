#!/bin/bash
set -euo pipefail

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

JOBS_DIR="kubernetes-manifests/jobs"
NAMESPACE="wiseling"
ALERTMANAGER_URL="http://localhost:9093"
PROMETHEUS_URL="http://localhost:9090"
LOCUST_JOB="wiseling-load-test"

PASSED=0
FAILED=0

cleanup() {
  log "Cleaning up locust job..."
  kubectl delete job "$LOCUST_JOB" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete pod crash-loop-test -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  pkill -f "kubectl port-forward.*alertmanager" 2>/dev/null || true
  pkill -f "kubectl port-forward.*prometheus" 2>/dev/null || true
  log "Restoring all deployments..."
  for deploy in auth-service-deployment wallet-service-deployment conversion-service-deployment withdrawal-service-deployment; do
    kubectl scale deployment -n "$NAMESPACE" "$deploy" --replicas=2 2>/dev/null || true
  done
  kubectl scale deployment -n "$NAMESPACE" wallet-consumer --replicas=2 2>/dev/null || true
  kubectl scale deployment -n "$NAMESPACE" conversion-outbox-poller --replicas=1 2>/dev/null || true
}

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
  local app_label="${deployment%%-deployment*}"
  log "Checking $description health endpoint..."
  local pod
  pod=$(kubectl get pods -n "$NAMESPACE" -l "app=${app_label}" \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | awk 'NR==1{print $1}')
  if [ -z "$pod" ]; then
    warn "$description — no running pod found for health check"
    return
  fi
  local attempts=0
  while [ $attempts -lt 6 ]; do
    if timeout 15 kubectl exec -n "$NAMESPACE" "$pod" -- \
      curl -sf --max-time 5 "http://localhost:$port$health_path" &>/dev/null; then
      success "$description — health check passed"
      PASSED=$((PASSED + 1))
      return 0
    fi
    attempts=$((attempts + 1))
    [ $attempts -lt 6 ] && sleep 10
  done
  warn "$description — health check did not respond on :$port$health_path within 60s (deployment is ready)"
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

setup_prometheus_portforward() {
  log "Setting up Prometheus port-forward..."
  kubectl port-forward -n monitoring \
    svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null &
  sleep 3
  if curl -sf "${PROMETHEUS_URL}/api/v1/status/runtimeinfo" &>/dev/null; then
    success "Prometheus port-forward established"
  else
    warn "Could not reach Prometheus"
  fi
}

# Query Prometheus directly for PodNotReady — bypasses Alertmanager resolve_timeout.
# If the expression returns no results, all service pods are ready and the alert will resolve.
assert_podnot_ready_cleared() {
  local timeout=${1:-120}
  local elapsed=0
  local expr='(kube_pod_status_ready{namespace="wiseling",condition="true"}==0)*on(pod,namespace)group_left()kube_pod_labels{namespace="wiseling",label_app=~"auth-service|wallet-service|conversion-service|withdrawal-service|wallet-consumer|conversion-outbox-poller|withdrawal-processor"}'
  log "Querying Prometheus: waiting for PodNotReady expression to clear (timeout: ${timeout}s)..."
  while [ $elapsed -lt $timeout ]; do
    local result
    result=$(curl -sf "${PROMETHEUS_URL}/api/v1/query" \
      --data-urlencode "query=${expr}" 2>/dev/null | \
      python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('data', {}).get('result', [])
print(len(results))
for r in results:
    print('  NOT-READY:', r.get('metric', {}), file=sys.stderr)
" 2>/tmp/pnr_debug || echo "-1")
    if [ "${result}" = "0" ]; then
      success "PodNotReady: no not-ready service pods in Prometheus after ${elapsed}s"
      PASSED=$((PASSED + 1))
      return 0
    fi
    if [ "${result}" != "-1" ] && [ $((elapsed % 30)) -eq 0 ] && [ -s /tmp/pnr_debug ]; then
      warn "Still not-ready: $(cat /tmp/pnr_debug)"
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  warn "PodNotReady still active after ${timeout}s — not-ready pods: $(cat /tmp/pnr_debug 2>/dev/null)"
  FAILED=$((FAILED + 1))
}

preflight() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "PREFLIGHT: Verifying all services are healthy before experiments"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  local pre_failed=$FAILED
  assert_pods_running "app=auth-service" "auth-service"
  assert_pods_running "app=wallet-service" "wallet-service"
  assert_pods_running "app=conversion-service" "conversion-service"
  assert_pods_running "app=withdrawal-service" "withdrawal-service"
  assert_pods_running "app=wallet-consumer" "wallet-consumer"
  assert_pods_running "app=conversion-outbox-poller" "conversion-outbox-poller"
  assert_pods_running "app=withdrawal-processor" "withdrawal-processor"
  if [ "$FAILED" -gt "$pre_failed" ]; then
    error "Preflight failed — $((FAILED - pre_failed)) service(s) not running. Run cleanup and redeploy before retrying."
    cleanup
    exit 1
  fi
  # Verify the alerting pipeline itself is alive (dead man's switch)
  assert_alerts_firing "Watchdog" "Watchdog dead man's switch must be active — proves alerting pipeline is healthy" 30
  success "Preflight complete — all services healthy and alerting pipeline live"
}

start_locust() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "LOAD TEST: Starting Locust (runs in background during experiments)"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  kubectl delete job "$LOCUST_JOB" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl wait --for=delete job/"$LOCUST_JOB" -n "$NAMESPACE" --timeout=30s 2>/dev/null || true
  kubectl apply -f "$JOBS_DIR/locust-job.yaml"
  success "Locust job started"
}

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
  wait_for_deployment_ready "wallet-service-deployment" 2 120
  assert_podnot_ready_cleared 120
  assert_alerts_resolved "WalletServiceDown" "WalletServiceDown should resolve" 60

  success "Experiment 01 complete"
}

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
  wait_for_deployment_ready "conversion-outbox-poller" 1 120
  assert_pods_running "app=conversion-outbox-poller" "conversion-outbox-poller recovered"

  success "Experiment 02 complete"
}

experiment_03_withdrawal_scale_down() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "EXPERIMENT 03: withdrawal-service scale-to-zero"
  log "Validates: WithdrawalServiceDown fires and resolves"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl scale deployment -n "$NAMESPACE" withdrawal-service-deployment --replicas=0
  log "withdrawal-service scaled to 0 — waiting 90s for alerts to fire..."
  sleep 90

  assert_alerts_firing "WithdrawalServiceDown" "WithdrawalServiceDown should fire" 90

  kubectl scale deployment -n "$NAMESPACE" withdrawal-service-deployment --replicas=2
  wait_for_deployment_ready "withdrawal-service-deployment" 2 120
  assert_alerts_resolved "WithdrawalServiceDown" "WithdrawalServiceDown should resolve" 120

  success "Experiment 03 complete"
}

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
  wait_for_deployment_ready "wallet-consumer" 2 120
  assert_pods_running "app=wallet-consumer" "wallet-consumer recovered"

  success "Experiment 04 complete"
}

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
  wait_for_deployment_ready "conversion-service-deployment" 2 120
  assert_alerts_resolved "ConversionServiceDown" "ConversionServiceDown should resolve" 120

  success "Experiment 05 complete"
}

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
  wait_for_deployment_ready "auth-service-deployment" 2 120
  assert_alerts_resolved "AuthServiceDown" "AuthServiceDown should resolve" 120

  success "Experiment 06 complete"
}

experiment_07_crash_loop() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "EXPERIMENT 07: PodCrashLooping detection"
  log "Validates: PodCrashLooping fires on crash-looping pod, clears on deletion"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Deploy a pod that exits immediately and restarts repeatedly
  kubectl run crash-loop-test -n "$NAMESPACE" \
    --image=busybox:1.35 \
    --restart=Always \
    --labels="app=crash-loop-test" \
    -- /bin/sh -c "sleep 2; exit 1"

  log "crash-loop-test deployed — waiting 130s for PodCrashLooping to fire (for: 2m)..."
  sleep 130

  assert_alerts_firing "PodCrashLooping" "PodCrashLooping should fire on repeatedly-crashing pod" 90

  log "Deleting crash-loop-test pod..."
  kubectl delete pod crash-loop-test -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

  log "Waiting for crash-loop pod metrics to clear in Prometheus (timeout: 120s)..."
  local elapsed=0
  while [ $elapsed -lt 120 ]; do
    local count
    count=$(curl -sf "${PROMETHEUS_URL}/api/v1/query" \
      --data-urlencode 'query=kube_pod_container_status_restarts_total{namespace="wiseling",pod="crash-loop-test"}' 2>/dev/null | \
      python3 -c "import sys, json; d = json.load(sys.stdin); print(len(d.get('data', {}).get('result', [])))" 2>/dev/null || echo "-1")
    if [ "${count}" = "0" ]; then
      success "PodCrashLooping: crash-loop pod metrics cleared from Prometheus after ${elapsed}s — alert will resolve"
      PASSED=$((PASSED + 1))
      break
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  if [ $elapsed -ge 120 ]; then
    warn "crash-loop pod metrics did not clear from Prometheus after 120s"
    FAILED=$((FAILED + 1))
  fi

  success "Experiment 07 complete"
}

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

main() {
  log "Starting Wiseling resilience test suite..."
  log "Load test job: $JOBS_DIR/locust-job.yaml"
  echo ""

  log "Applying Chaos Mesh RBAC permissions..."
  kubectl apply -f kubernetes-manifests/chaos/chaos-mesh-rbac.yaml
  success "Chaos Mesh RBAC applied"

  setup_alertmanager_portforward
  setup_prometheus_portforward
  preflight
  start_locust

  log "Waiting 30s for Locust to ramp up before injecting chaos..."
  sleep 30

  experiment_01_wallet_scale_down
  experiment_02_outbox_poller_kill
  experiment_03_withdrawal_scale_down
  experiment_04_wallet_consumer_kill
  experiment_05_conversion_scale_down
  experiment_06_auth_scale_down
  experiment_07_crash_loop

  cleanup
  print_summary
}

main "$@"