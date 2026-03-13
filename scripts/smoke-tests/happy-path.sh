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

log "Happy path: Register user..."
REGISTER=$(curl -sf -X POST $BASE_URL/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email": "smoke@test.com", "password": "Test1234!"}')
echo "$REGISTER"

log "Happy path: Login..."
LOGIN=$(curl -sf -X POST $BASE_URL/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "smoke@test.com", "password": "Test1234!"}')
TOKEN=$(echo "$LOGIN" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
echo "Token: $TOKEN"

log "Happy path: Check wallet balances..."
curl -sf $BASE_URL/api/v1/wallet/balances \
  -H "Authorization: Bearer $TOKEN"

log "Happy path: Create conversion..."
curl -sf -X POST $BASE_URL/api/v1/conversions \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "from_currency": "USD",
    "to_currency": "EUR",
    "amount": 100.00,
    "idempotency_key": "smoke-test-001"
  }'

log "Happy path: Wait for wallet consumer to process..."
sleep 5

log "Happy path: Check wallet balances updated..."
curl -sf $BASE_URL/api/v1/wallet/balances \
  -H "Authorization: Bearer $TOKEN"

log "Happy path: Create withdrawal..."
curl -sf -X POST $BASE_URL/api/v1/withdrawals/transfer \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "currency": "USD",
    "amount": 50.00,
    "idempotency_key": "smoke-test-002",
    "to_account_number": "1234567890"
  }'

log "Happy path: All tests passed ✅"
