#!/bin/bash
set -euo pipefail


BASE_URL="http://k8s-wiseling-8924e1e1d0-1319653657.ap-southeast-2.elb.amazonaws.com/"
EMAIL="smoke$(date +%s)@test.com"

log() {
  echo -e "\033[1;34m[$(date '+%Y-%m-%d %H:%M:%S')] $*\033[0m"
}
error_handler() {
  echo -e "\033[1;31m[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Script failed at line $1.\033[0m" >&2
  exit 1
}
trap 'error_handler $LINENO' ERR



log "Happy path: Register user..."
REGISTER_RESPONSE=$(curl -w '\nHTTP_STATUS:%{http_code}\n' -X POST $BASE_URL/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -H "Accept: */*" \
  -H "Origin: $BASE_URL" \
  -H "Referer: $BASE_URL" \
  -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36" \
  -d '{"email": "'$EMAIL'", "password": "Test1234!"}')
REGISTER_BODY=$(echo "$REGISTER_RESPONSE" | sed -e '/HTTP_STATUS:/d')
REGISTER_STATUS=$(echo "$REGISTER_RESPONSE" | grep HTTP_STATUS | cut -d: -f2)
echo "Register response: $REGISTER_BODY"
echo "Register status: $REGISTER_STATUS"
if [ "$REGISTER_STATUS" -ne 201 ]; then
  log "Registration failed with status $REGISTER_STATUS"
  exit 1
fi

log "Happy path: Login..."
LOGIN=$(curl -sf -X POST $BASE_URL/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -H "Accept: */*" \
  -H "Origin: $BASE_URL" \
  -H "Referer: $BASE_URL" \
  -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36" \
  -d '{"email": "'$EMAIL'", "password": "Test1234!"}')
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
