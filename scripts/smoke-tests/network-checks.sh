#!/bin/bash
set -euo pipefail

BASE_URL="http://alb-url-gotten-from-ingress"

log() {
  echo -e "\033[1;34m[$(date '+%Y-%m-%d %H:%M:%S')] $*\033[0m"
}
error_handler() {
  echo -e "\033[1;31m[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Script failed at line $1.\033[0m" >&2
  exit 1
}
trap 'error_handler $LINENO' ERR

log "Network: DNS resolution and ping for ALB host..."
ALB_HOST=$(echo $BASE_URL | awk -F/ '{print $3}')
nslookup $ALB_HOST || true
ping -c 2 $ALB_HOST || true

for svc in auth-service wallet-service conversion-service withdrawal-service; do
  log "Health check: $svc..."
  curl -sf --write-out "\nStatus: %{http_code} | Time: %{time_total}s\n" http://$svc:8000/health || true
done

log "Network and service health checks completed ✅"
