#!/bin/bash
set -e

BASE_URL="http://alb-url-gotten-from-ingress"

echo "1. Health checks..."
curl -f $BASE_URL/api/v1/auth/health
curl -f $BASE_URL/api/v1/wallets/health
curl -f $BASE_URL/api/v1/conversions/health
curl -f $BASE_URL/api/v1/withdrawals/health

echo "2. Register user..."
REGISTER=$(curl -sf -X POST $BASE_URL/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email": "smoke@test.com", "password": "Test1234!"}')
echo $REGISTER

echo "3. Login..."
LOGIN=$(curl -sf -X POST $BASE_URL/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "smoke@test.com", "password": "Test1234!"}')
TOKEN=$(echo $LOGIN | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
echo "Token: $TOKEN"

echo "4. Check wallet balance..."
curl -sf $BASE_URL/api/v1/wallets \
  -H "Authorization: Bearer $TOKEN"

echo "5. Create conversion..."
curl -sf -X POST $BASE_URL/api/v1/conversions \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "from_currency": "USD",
    "to_currency": "EUR",
    "amount": "100.00",
    "idempotency_key": "smoke-test-001"
  }'

echo "6. Wait for wallet consumer to process..."
sleep 5

echo "7. Check balance updated..."
curl -sf $BASE_URL/api/v1/wallets \
  -H "Authorization: Bearer $TOKEN"

echo "8. Create withdrawal..."
curl -sf -X POST $BASE_URL/api/v1/withdrawals \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "currency": "USD",
    "amount": "50.00",
    "iban": "GB29NWBK60161331926819",
    "idempotency_key": "smoke-test-002"
  }'

echo "All smoke tests passed ✅"