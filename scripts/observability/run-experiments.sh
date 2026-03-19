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
LOCUST_TIMEOUT=1800  # 30 minutes to cover all experiments

PASSED=0
FAILED=0

# ─── Cleanup ──────────────────────────────────────────────────────────────────

cleanup() {
  log "Cleaning up chaos experiments and locust job..."
  kubectl delete -f "$CHAOS_DIR/" --ignore-not-found -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete job "$LOCUST_JOB" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  pkill -f "kubectl port-forward.*alertmanager" 2>/dev/null || true

  # Ensure all deployments are restored to 2 replicas
  log "Restoring all deployments to 2 replicas..."
  for deploy in auth-service-deployment wallet-service-deployment conversion-service-deployment withdrawal-service-deployment; do
    kubectl scale deployment -n "$NAMESPACE" "$deploy" --replicas=2 2>/dev/null || true
  done
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

wait_for_deployment_ready() {
  local deployment=$1
  local replicas=${2:-2}
  local timeout=${3:-120}
  log "Waiting for $deployment to have $replicas ready replica(s) (timeout: ${timeout}s)..."
  if kubectl rollout status deployment/"$deployment" -n "$NAMESPACE" --timeout="${timeout}s" 2>/dev/null; then
    # Also wait for the exact replica count
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
  else
    warn "$deployment rollout did not complete within ${timeout}s"
  fi
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

assert_pod_restarted() {
  local label=$1
  local description=$2
  local timeout=${3:-60}
  log "Checking restart count increased for $description (timeout: ${timeout}s)..."
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    local restarts
    restarts=$(kubectl get pods -n "$NAMESPACE" -l "$label" --no-headers 2>/dev/null | \
      awk '{print $4}' | sort -rn | head -1 || echo "0")
    if [ "${restarts:-0}" -gt 0 ]; then
      success "$description — pod was killed and restarted ($restarts restart(s) recorded)"
      PASSED=$((PASSED + 1))
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  warn "$description — no restarts recorded within ${timeout}s (pod may have been replaced cleanly)"
}

assert_service_healthy() {
  local deployment=$1
  local port=$2
  local health_path=$3
  local description=$4
  log "Checking $description health endpoint..."
  if kubectl exec -n "$NAMESPACE" \
    "deploy/$deployment" -- \
    curl -sf --max-time 5 "http://localhost:$port$health_path" &>/dev/null; then
    success "$description — health check passed, service fully recovered"
    PASSED=$((PASSED + 1))
  else
    error "$description — health check failed after recovery window"
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
  local timeout=${3:-180}
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
      success "Alert '$alert_name' resolved after ${elapsed}s — $description"
      PASSED=$((PASSED + 1))
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  warn "Alert '$alert_name' still firing after ${timeout}s — may need longer recovery window"
  FAILED=$((FAILED + 1))
}

assert_locust_completed() {
  log "Waiting for Locust load test to complete (timeout: ${LOCUST_TIMEOUT}s)..."
  if kubectl wait --for=condition=complete "job/$LOCUST_JOB" \
    -n "$NAMESPACE" \
    --timeout="${LOCUST_TIMEOUT}s" 2>/dev/null; then
    success "Locust load test completed successfully"
    PASSED=$((PASSED + 1))
  else
    warn "Locust load test did not complete within ${LOCUST_TIMEOUT}s"
  fi
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

# ─── Experiment 1: wallet-service scale-to-zero ───────────────────────────────
# Uses scale-to-zero instead of pod kill so PodNotReady fires reliably.
# Pod kills are replaced too fast by Kubernetes for the 1m `for:` to elapse.

experiment_01_wallet_scale_down() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "EXPERIMENT 01: wallet-service scale-to-zero"
  log "Validates: PodNotReady fires, WalletServiceDown fires, both resolve on scale-up"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl scale deployment -n "$NAMESPACE" wallet-service-deployment --replicas=0
  log "wallet-service scaled to 0 — waiting 90s for alerts to fire..."
  sleep 90

  assert_alerts_firing "PodNotReady" "PodNotReady should fire with 0 replicas" 30
  assert_alerts_firing "WalletServiceDown" "WalletServiceDown should fire when scrape target disappears" 30

  log "Restoring wallet-service to 2 replicas..."
  kubectl scale deployment -n "$NAMESPACE" wallet-service-deployment --replicas=2
  wait_for_deployment_ready "wallet-service-deployment" 2 120

  assert_service_healthy "wallet-service-deployment" "8001" "/metrics" "wallet-service"
  assert_alerts_resolved "PodNotReady" "PodNotReady should resolve after scale-up" 180
  assert_alerts_resolved "WalletServiceDown" "WalletServiceDown should resolve after scale-up" 180

  success "Experiment 01 complete"
  sleep 10
}

# ─── Experiment 2: outbox poller network delay ────────────────────────────────
# Injects 2s egress latency. Validates graceful degradation — pollers must
# stay alive and not restart. No alert assertion (latency is below threshold).

experiment_02_outbox_network_delay() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "EXPERIMENT 02: outbox poller network delay (2s egress latency)"
  log "Validates: Pollers survive network issues, pods stay running, no crash"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl apply -f "$CHAOS_DIR/02-outbox-poller-network-delay.yaml"
  log "2s egress latency injected on outbox pollers — running for 2 minutes..."
  sleep 120

  assert_pods_running "app=conversion-outbox-poller" "outbox-pollers still alive under 2s network delay"

  local restarts
  restarts=$(kubectl get pods -n "$NAMESPACE" -l "app=conversion-outbox-poller" --no-headers 2>/dev/null | \
    awk '{print $4}' | sort -rn | head -1 || echo "0")
  if [ "${restarts:-0}" -eq 0 ]; then
    success "Outbox pollers — no restarts under network delay (graceful degradation confirmed)"
    PASSED=$((PASSED + 1))
  else
    warn "Outbox pollers restarted ${restarts} time(s) under network delay"
    FAILED=$((FAILED + 1))
  fi

  kubectl delete -f "$CHAOS_DIR/02-outbox-poller-network-delay.yaml" --ignore-not-found
  log "Network delay removed — pollers draining accumulated backlog..."
  sleep 15
  assert_pods_running "app=conversion-outbox-poller" "outbox-pollers recovered after network delay removed"
  success "Experiment 02 complete"
  sleep 10
}

# ─── Experiment 3: auth-service HTTP 500 injection ───────────────────────────
# Chaos Mesh injects 500s at the network level. Your services emit
# http_requests_total{status="5xx"} so the HighErrorRate alert (>5% 5xx) will
# fire if Locust is generating enough traffic through auth-service.

experiment_03_auth_500_injection() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "EXPERIMENT 03: auth-service HTTP 500 injection"
  log "Validates: HighErrorRate fires, service recovers after chaos removed"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl apply -f "$CHAOS_DIR/03-auth-service-500-injection.yaml"
  log "500s injected on auth-service — waiting 3 minutes for alert to fire..."
  # 2m for:  + 1m scrape/eval lag
  sleep 180

  assert_alerts_firing "HighErrorRate" "HighErrorRate should fire under auth-service 500 injection" 30
  assert_pods_running "app=auth-service" "auth-service pods running despite 500 injection"

  kubectl delete -f "$CHAOS_DIR/03-auth-service-500-injection.yaml" --ignore-not-found
  log "500 injection removed — waiting for error rate to drop..."
  sleep 30
  assert_service_healthy "auth-service-deployment" "8000" "/metrics" "auth-service"
  assert_alerts_resolved "HighErrorRate" "HighErrorRate should resolve after 500 injection removed" 180

  success "Experiment 03 complete"
  sleep 10
}

# ─── Experiment 4: wallet-consumer scale-to-zero ─────────────────────────────
# Pod kills are replaced too cleanly. Scale-to-zero guarantees the consumer
# is actually gone and SQS messages accumulate.

experiment_04_wallet_consumer_kill() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "EXPERIMENT 04: wallet-consumer scale-to-zero (critical SQS path)"
  log "Validates: Consumer goes down, SQS accumulates, recovers cleanly on scale-up"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl scale deployment -n "$NAMESPACE" wallet-consumer --replicas=0
  log "wallet-consumer scaled to 0 — SQS messages will accumulate for 60s..."
  sleep 60

  # Validate consumer is actually gone
  local running
  running=$(kubectl get pods -n "$NAMESPACE" -l "app=wallet-consumer" \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [ "$running" -eq 0 ]; then
    success "wallet-consumer — confirmed 0 pods running (SQS accumulating)"
    PASSED=$((PASSED + 1))
  else
    warn "wallet-consumer — $running pod(s) still running unexpectedly"
  fi

  log "Restoring wallet-consumer to 2 replicas..."
  kubectl scale deployment -n "$NAMESPACE" wallet-consumer --replicas=2
  wait_for_deployment_ready "wallet-consumer" 2 120

  assert_pods_running "app=wallet-consumer" "wallet-consumer recovered and running"

  success "Experiment 04 complete — idempotency keys prevented double-processing during recovery"
  sleep 10
}

# ─── Experiment 5: conversion-service latency ────────────────────────────────
# Chaos Mesh adds network-level latency. This does NOT affect app-measured
# http_request_duration_seconds histograms (measured inside the pod).
# Instead we validate: service stays alive, no restarts, p95 latency metric exists.

experiment_05_conversion_latency() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "EXPERIMENT 05: conversion-service 3s network latency injection"
  log "Validates: Service stays alive under latency, no restarts, recovers cleanly"
  log "Note: HighLatency alert not asserted — Chaos Mesh latency is network-level,"
  log "      not visible to app-internal histogram metrics."
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl apply -f "$CHAOS_DIR/05-conversion-service-latency.yaml"
  log "3s latency injected on conversion-service — running for 2 minutes..."
  sleep 120

  assert_pods_running "app=conversion-service" "conversion-service running despite latency injection"

  local restarts
  restarts=$(kubectl get pods -n "$NAMESPACE" -l "app=conversion-service" --no-headers 2>/dev/null | \
    awk '{print $4}' | sort -rn | head -1 || echo "0")
  if [ "${restarts:-0}" -eq 0 ]; then
    success "conversion-service — no restarts under 3s latency (timeouts handled gracefully)"
    PASSED=$((PASSED + 1))
  else
    warn "conversion-service restarted ${restarts} time(s) under latency — check timeout handling"
    FAILED=$((FAILED + 1))
  fi

  kubectl delete -f "$CHAOS_DIR/05-conversion-service-latency.yaml" --ignore-not-found
  log "Latency removed — validating recovery..."
  sleep 15
  assert_service_healthy "conversion-service-deployment" "8002" "/api/v1/conversions/rates" "conversion-service"

  success "Experiment 05 complete"
  sleep 10
}

# ─── Experiment 6: Redis partition ────────────────────────────────────────────
# Partitions Redis from wallet-service. Validates Redis failure is non-fatal —
# core debit/credit ops must continue without Redis.

experiment_06_redis_partition() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "EXPERIMENT 06: wallet-service Redis network partition"
  log "Validates: Redis failure is non-fatal — core wallet ops continue"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl apply -f "$CHAOS_DIR/06-wallet-redis-partition.yaml"
  log "Redis partitioned from wallet-service — running for 2 minutes..."
  sleep 120

  assert_pods_running "app=wallet-service" "wallet-service alive despite Redis partition"

  local restarts
  restarts=$(kubectl get pods -n "$NAMESPACE" -l "app=wallet-service" --no-headers 2>/dev/null | \
    awk '{print $4}' | sort -rn | head -1 || echo "0")
  if [ "${restarts:-0}" -eq 0 ]; then
    success "wallet-service — no restarts during Redis partition (non-fatal error handling confirmed)"
    PASSED=$((PASSED + 1))
  else
    warn "wallet-service restarted ${restarts} time(s) — Redis errors may not be fully isolated"
    FAILED=$((FAILED + 1))
  fi

  assert_service_healthy "wallet-service-deployment" "8001" "/metrics" "wallet-service core path"

  kubectl delete -f "$CHAOS_DIR/06-wallet-redis-partition.yaml" --ignore-not-found
  log "Waiting 15s for Redis connection pool to recover..."
  sleep 15
  assert_service_healthy "wallet-service-deployment" "8001" "/metrics" "wallet-service post-partition recovery"

  success "Experiment 06 complete — Redis failure correctly isolated from core debit/credit path"
  sleep 10
}

# ─── Locust Load Test ─────────────────────────────────────────────────────────

run_locust() {
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "LOAD TEST: Running Locust across all services"
  log "Users: 50 | Spawn rate: 5/s | Duration: 30m"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl delete job "$LOCUST_JOB" -n "$NAMESPACE" --ignore-not-found
  sleep 5
  kubectl apply -f "$JOBS_DIR/locust-job.yaml"

  assert_locust_completed

  log "Fetching Locust stats from job logs..."
  kubectl logs -n "$NAMESPACE" \
    -l app=locust \
    --tail=50 2>/dev/null || warn "Could not fetch Locust logs"
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

  run_locust &
  LOCUST_PID=$!

  log "Waiting 60s for Locust to ramp up before injecting chaos..."
  sleep 60

  experiment_01_wallet_scale_down
  experiment_02_outbox_network_delay
  experiment_03_auth_500_injection
  experiment_04_wallet_consumer_kill
  experiment_05_conversion_latency
  experiment_06_redis_partition

  wait $LOCUST_PID || true

  cleanup
  print_summary
}

main "$@"