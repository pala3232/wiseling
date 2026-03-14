#!/bin/bash
set -euo pipefail

BASE_URL="http://k8s-wiseling-8924e1e1d0-1319653657.ap-southeast-2.elb.amazonaws.com/"

log() {
  echo -e "\033[1;34m[$(date '+%Y-%m-%d %H:%M:%S')] $*\033[0m"
}
error_handler() {
  echo -e "\033[1;31m[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Script failed at line $1.\033[0m" >&2
  exit 1
}
trap 'error_handler $LINENO' ERR

LOGIN=$(curl -sf -X POST $BASE_URL/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "smoke@test.com", "password": "Test1234!"}')
TOKEN=$(echo "$LOGIN" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

log "Edge case: Duplicate idempotency key for conversion..."
for i in 1 2; do
  curl -sf -w "\nStatus: %{http_code} | Time: %{time_total}s\n" -X POST $BASE_URL/api/v1/conversions \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "from_currency": "USD",
      "to_currency": "EUR",
      "amount": 100.00,
      "idempotency_key": "smoke-test-001"
    }'
done

log "Edge case tests completed ✅"
