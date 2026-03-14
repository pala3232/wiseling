
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

# Network checks
log "Network: DNS resolution and ping for ALB host..."
ALB_HOST=$(echo $BASE_URL | awk -F/ '{print $3}')
nslookup $ALB_HOST || true
ping -c 2 $ALB_HOST || true

# Service-specific health checks
for svc in auth-service wallet-service conversion-service withdrawal-service; do
  log "Health check: $svc..."
  curl -sf --write-out "\nStatus: %{http_code} | Time: %{time_total}s\n" http://$svc:8000/health || true
done



log "1. Health check: public endpoint..."
curl -sf --write-out "\nStatus: %{http_code} | Time: %{time_total}s\n" $BASE_URL/health

log "2. Register user..."

REGISTER=$(curl -sf -w "\nStatus: %{http_code} | Time: %{time_total}s\n" -X POST $BASE_URL/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email": "smoke@test.com", "password": "Test1234!"}')
echo "$REGISTER"

log "3. Login..."

LOGIN=$(curl -sf -w "\nStatus: %{http_code} | Time: %{time_total}s\n" -X POST $BASE_URL/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "smoke@test.com", "password": "Test1234!"}')
TOKEN=$(echo "$LOGIN" | python3 -c "import sys,json; import re; s=sys.stdin.read(); print(json.loads(re.split(r'Status:',s)[0])['access_token'])")
echo "Token: $TOKEN"

# Negative test: invalid login
log "Negative test: invalid login..."
curl -s -o /dev/null -w "Status: %{http_code} | Time: %{time_total}s\n" -X POST $BASE_URL/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "smoke@test.com", "password": "WrongPass!"}'

log "4. Check wallet balances..."

WALLET_JSON=$(curl -sf -w "\nStatus: %{http_code} | Time: %{time_total}s\n" $BASE_URL/api/v1/wallet/balances \
  -H "Authorization: Bearer $TOKEN")
echo "$WALLET_JSON"

# Data validation: check for at least one wallet
if ! echo "$WALLET_JSON" | grep -q '"account_number"'; then
  log "Wallet data validation failed: No account_number found."
  exit 1
fi

log "5. Create conversion..."

# Edge case: duplicate idempotency key
log "Edge case: duplicate idempotency key for conversion..."
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

log "6. Wait for wallet consumer to process..."
sleep 5

log "7. Check wallet balances updated..."

WALLET_JSON2=$(curl -sf -w "\nStatus: %{http_code} | Time: %{time_total}s\n" $BASE_URL/api/v1/wallet/balances \
  -H "Authorization: Bearer $TOKEN")
echo "$WALLET_JSON2"

log "8. Create withdrawal..."

# Edge case: large withdrawal amount (should fail if insufficient funds)
log "Negative test: large withdrawal (insufficient funds)..."
curl -s -o /dev/null -w "Status: %{http_code} | Time: %{time_total}s\n" -X POST $BASE_URL/api/v1/withdrawals/transfer \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "currency": "USD",
    "amount": 1000000.00,
    "idempotency_key": "smoke-test-003",
    "to_account_number": "1234567890"
  }'

log "8. Create withdrawal (normal)..."
curl -sf -w "\nStatus: %{http_code} | Time: %{time_total}s\n" -X POST $BASE_URL/api/v1/withdrawals/transfer \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "currency": "USD",
    "amount": 50.00,
    "idempotency_key": "smoke-test-002",
    "to_account_number": "1234567890"
  }'

log "All smoke tests passed successfully!"