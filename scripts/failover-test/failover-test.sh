#!/bin/bash
# =============================================================================
# Wiseling Failover Test
# Measures end-to-end failover time from primary failure to DR serving traffic.
#
# Usage:
#   ./failover-test.sh --domain wiseling.xyz
#
# What it does:
#   1. Records baseline (primary ALB serving traffic)
#   2. Scales down all primary deployments to 0 (triggers Route53 health check)
#   3. Polls until Route53 health check reports unhealthy
#   4. Polls until DNS resolves to the DR ALB
#   5. Polls until DR endpoint returns HTTP 200
#   6. Reports total failover time
#   7. Restores primary deployments
#   8. Reports total recovery time
#
# Prerequisites: aws cli, kubectl (configured for primary cluster), dig, curl
# =============================================================================

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────
DOMAIN=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --domain) DOMAIN="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ -z "$DOMAIN" ]]; then
  echo "Usage: $0 --domain <your-domain>"
  exit 1
fi

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${CYAN}[$(date '+%H:%M:%S')] $*${NC}"; }
ok()      { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $*${NC}"; }
fail()    { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $*${NC}"; }
elapsed() { echo $(( $(date +%s) - $1 ))s; }

NAMESPACE="wiseling"
DEPLOYMENTS=(
  auth-service-deployment
  wallet-service-deployment
  conversion-service-deployment
  withdrawal-service-deployment
  frontend-deployment
)

# ── Helpers ───────────────────────────────────────────────────────────────────
get_primary_alb() {
  aws eks update-kubeconfig --region ap-southeast-2 --name wiseling-eks-cluster &>/dev/null
  kubectl get ingress wiseling-ingress -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo ""
}

get_dr_alb() {
  aws eks update-kubeconfig --region ap-southeast-1 --name wiseling-eks-cluster-sgp &>/dev/null
  kubectl get ingress wiseling-ingress -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo ""
}

get_health_check_id() {
  aws route53 list-health-checks \
    --query "HealthChecks[?HealthCheckConfig.FullyQualifiedDomainName=='${PRIMARY_ALB}'].Id | [0]" \
    --output text 2>/dev/null || echo ""
}

current_dns() {
  nslookup "$DOMAIN" 8.8.8.8 2>/dev/null \
    | awk '/^Address(es)?:/ && !/8\.8\.8\.8/ {print $2; exit}' || echo ""
}

health_check_status() {
  local hc_id="$1"
  aws route53 get-health-check-status \
    --health-check-id "$hc_id" \
    --query 'HealthCheckObservations[0].StatusReport.Status' \
    --output text 2>/dev/null || echo "unknown"
}

endpoint_status() {
  local url="$1"
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000"
}

scale_primary() {
  local replicas="$1"
  aws eks update-kubeconfig --region ap-southeast-2 --name wiseling-eks-cluster &>/dev/null
  for deploy in "${DEPLOYMENTS[@]}"; do
    kubectl scale deployment "$deploy" -n "$NAMESPACE" --replicas="$replicas" 2>/dev/null || true
  done
}

# ── Preflight ─────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Wiseling Failover Test"
echo "  Domain: $DOMAIN"
echo "═══════════════════════════════════════════════════════"
echo ""

log "Fetching baseline state..."

PRIMARY_ALB=$(get_primary_alb)
DR_ALB=$(get_dr_alb)
HC_ID=$(get_health_check_id)

if [[ -z "$PRIMARY_ALB" ]]; then
  fail "Could not fetch primary ALB — is kubectl configured for primary cluster?"
  exit 1
fi
if [[ -z "$DR_ALB" ]]; then
  fail "Could not fetch DR ALB — is kubectl configured for DR cluster?"
  exit 1
fi
if [[ -z "$HC_ID" || "$HC_ID" == "None" ]]; then
  warn "Could not find Route53 health check ID — health check polling will be skipped"
fi

BASELINE_DNS=$(current_dns)
BASELINE_STATUS=$(endpoint_status "https://$DOMAIN/api/v1/auth/health")

ok "Primary ALB:   $PRIMARY_ALB"
ok "DR ALB:        $DR_ALB"
ok "Health Check:  ${HC_ID:-not found}"
ok "Current DNS:   ${BASELINE_DNS:-unresolved}"
ok "Endpoint:      HTTP $BASELINE_STATUS"
echo ""

if [[ "$BASELINE_STATUS" != "200" ]]; then
  warn "Primary endpoint not returning 200 before test — results may be unreliable"
fi

read -p "$(echo -e ${YELLOW}Press ENTER to start failover test. This will scale down primary pods.${NC}) "
echo ""

# ── Phase 1: Trigger failover ─────────────────────────────────────────────────
log "Phase 1: Scaling down primary deployments to 0..."
FAILOVER_START=$(date +%s)

scale_primary 0
ok "Primary deployments scaled to 0"

# ── Phase 2: Wait for health check to go unhealthy ────────────────────────────
if [[ -n "$HC_ID" && "$HC_ID" != "None" ]]; then
  log "Phase 2: Waiting for Route53 health check to report unhealthy..."
  HC_UNHEALTHY_TIME=""
  while true; do
    STATUS=$(health_check_status "$HC_ID")
    if [[ "$STATUS" == *"Failure"* ]] || [[ "$STATUS" == *"failure"* ]]; then
      HC_UNHEALTHY_TIME=$(date +%s)
      ok "Health check unhealthy after $(elapsed $FAILOVER_START) — status: $STATUS"
      break
    fi
    echo -ne "\r  Health check: $STATUS ($(elapsed $FAILOVER_START) elapsed)    "
    sleep 5
  done
  echo ""
else
  log "Phase 2: Skipping health check poll (ID not found)"
fi

# ── Phase 3: Wait for DNS to flip ─────────────────────────────────────────────
log "Phase 3: Polling DNS until it changes from baseline (Route53 failover)..."
DNS_FLIPPED_TIME=""

while true; do
  RESOLVED=$(current_dns)
  if [[ -n "$RESOLVED" && "$RESOLVED" != "$BASELINE_DNS" ]]; then
    DNS_FLIPPED_TIME=$(date +%s)
    ok "DNS flipped after $(elapsed $FAILOVER_START) — now resolves to: $RESOLVED"
    break
  fi
  echo -ne "\r  DNS resolves to: ${RESOLVED:-unresolved} ($(elapsed $FAILOVER_START) elapsed)    "
  sleep 5
done
echo ""

# ── Phase 4: Wait for DR endpoint to return 200 ───────────────────────────────
log "Phase 4: Waiting for DR endpoint to return HTTP 200..."
DR_HEALTHY_TIME=""

while true; do
  CODE=$(endpoint_status "https://$DOMAIN/api/v1/auth/health")
  if [[ "$CODE" == "200" ]]; then
    DR_HEALTHY_TIME=$(date +%s)
    ok "DR endpoint healthy after $(elapsed $FAILOVER_START) — HTTP $CODE"
    break
  fi
  echo -ne "\r  https://$DOMAIN/api/v1/auth/health → HTTP $CODE ($(elapsed $FAILOVER_START) elapsed)    "
  sleep 5
done
echo ""

# ── Failover summary ──────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  FAILOVER COMPLETE"
echo "═══════════════════════════════════════════════════════"
[[ -n "$HC_UNHEALTHY_TIME" ]] && echo "  Health check unhealthy: $((HC_UNHEALTHY_TIME - FAILOVER_START))s"
[[ -n "$DNS_FLIPPED_TIME" ]]  && echo "  DNS flipped to DR:      $((DNS_FLIPPED_TIME - FAILOVER_START))s"
[[ -n "$DR_HEALTHY_TIME" ]]   && echo "  DR serving traffic:     $((DR_HEALTHY_TIME - FAILOVER_START))s"
echo "  ─────────────────────────────────────────────────────"
echo -e "  ${GREEN}Total failover time:    $(elapsed $FAILOVER_START)${NC}"
echo "═══════════════════════════════════════════════════════"
echo ""

# ── Phase 5: Restore primary ──────────────────────────────────────────────────
read -p "$(echo -e ${YELLOW}Press ENTER to restore primary deployments.${NC}) "
echo ""

log "Phase 5: Restoring primary deployments to 2 replicas..."
RECOVERY_START=$(date +%s)
scale_primary 2

log "Waiting for primary endpoint to return HTTP 200..."
while true; do
  CODE=$(endpoint_status "https://$DOMAIN/api/v1/auth/health")
  if [[ "$CODE" == "200" ]]; then
    ok "Primary endpoint healthy after $(elapsed $RECOVERY_START)"
    break
  fi
  echo -ne "\r  https://$DOMAIN/api/v1/auth/health → HTTP $CODE ($(elapsed $RECOVERY_START) elapsed)    "
  sleep 5
done
echo ""

log "Waiting for DNS to flip back to primary..."
while true; do
  RESOLVED=$(current_dns)
  if [[ "$RESOLVED" == "$BASELINE_DNS" ]]; then
    ok "DNS back to primary after $(elapsed $RECOVERY_START) — resolves to: $RESOLVED"
    break
  fi
  echo -ne "\r  DNS resolves to: ${RESOLVED:-unresolved} ($(elapsed $RECOVERY_START) elapsed)    "
  sleep 5
done
echo ""

echo "═══════════════════════════════════════════════════════"
echo "  RECOVERY COMPLETE"
echo -e "  ${GREEN}Total recovery time: $(elapsed $RECOVERY_START)${NC}"
echo "═══════════════════════════════════════════════════════"
echo ""
