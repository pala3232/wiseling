#!/usr/bin/env bash
# =============================================================================
# Wiseling Smoke Tests
# Runs against the live ALB. Tests the full happy path end-to-end.
# Usage: BASE_URL=https://your-alb-url ./scripts/smoke-tests/main.sh
# =============================================================================

set -euo pipefail

BASE_URL="${BASE_URL:-}"
PASS=0
FAIL=0
ERRORS=()

#  Colours 
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${YELLOW}[$(date '+%H:%M:%S')] $*${NC}"; }
ok()    { echo -e "${GREEN}  ✓ $*${NC}"; PASS=$((PASS+1)); }
fail()  { echo -e "${RED}  ✗ $*${NC}"; FAIL=$((FAIL+1)); ERRORS+=("$*"); }

#  Helpers 
require_env() {
  if [[ -z "$BASE_URL" ]]; then
    echo "ERROR: BASE_URL is not set."
    echo "Usage: BASE_URL=http://<alb-url> ./scripts/smoke-tests/main.sh"
    exit 1
  fi
}

# Make a request and return the response body.
req() {
  local method="$1" path="$2"
  shift 2
  curl -s -X "$method" "${BASE_URL}${path}" \
    -H "Content-Type: application/json" \
    "$@" || true
}

req_auth() {
  local method="$1" path="$2"
  shift 2
  curl -s -X "$method" "${BASE_URL}${path}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" \
    "$@" || true
}

req_auth2() {
  local method="$1" path="$2"
  shift 2
  curl -s -X "$method" "${BASE_URL}${path}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN2}" \
    "$@" || true
}

assert_field() {
  local label="$1" json="$2" field="$3" expected="$4"
  local actual
  actual=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('${field}',''))" 2>/dev/null || echo "")
  if [[ "$actual" == "$expected" ]]; then
    ok "$label: $field = $expected"
  else
    fail "$label: expected $field='$expected', got '$actual'"
  fi
}

assert_not_empty() {
  local label="$1" value="$2"
  if [[ -n "$value" && "$value" != "null" && "$value" != "None" ]]; then
    ok "$label"
  else
    fail "$label (got empty/null)"
  fi
}

assert_http() {
  local label="$1" code="$2" expected="$3"
  if [[ "$code" == "$expected" ]]; then
    ok "$label: HTTP $code"
  else
    fail "$label: expected HTTP $expected, got $code"
  fi
}

#  Test IDs (unique per run) 
TS=$(date +%s)
EMAIL1="smoketest1_${TS}@example.com"
EMAIL2="smoketest2_${TS}@example.com"
PASS1="SmokePass${TS}!"
TOKEN=""
TOKEN2=""
ACCOUNT1=""
ACCOUNT2=""
IDEMPOTENCY_KEY=""

# =============================================================================
require_env

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Wiseling Smoke Tests"
echo "  Target: $BASE_URL"
echo "═══════════════════════════════════════════════════════"
echo ""

#  1. Auth 
log "1. Auth — register & login"

# Register user 1
RESP=$(req POST /api/v1/auth/register -d "{\"email\":\"${EMAIL1}\",\"password\":\"${PASS1}\"}" 2>/dev/null) || { fail "Register user1 failed"; RESP="{}"; }
USER_ID1=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
assert_not_empty "Register user1 - got user id" "$USER_ID1"

# Register user 2
RESP2=$(req POST /api/v1/auth/register -d "{\"email\":\"${EMAIL2}\",\"password\":\"${PASS1}\"}" 2>/dev/null) || { fail "Register user2 failed"; RESP2="{}"; }
USER_ID2=$(echo "$RESP2" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
assert_not_empty "Register user2 - got user id" "$USER_ID2"

# Duplicate registration should fail
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${EMAIL1}\",\"password\":\"${PASS1}\"}")
assert_http "Duplicate registration rejected" "$HTTP_CODE" "400"

# Login user 1
LOGIN=$(curl -sf -X POST "${BASE_URL}/api/v1/auth/login" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${EMAIL1}&password=${PASS1}" 2>/dev/null) || { fail "Login user1 failed"; LOGIN="{}"; }
TOKEN=$(echo "$LOGIN" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
assert_not_empty "Login user1 - got token" "$TOKEN"

# Login user 2
LOGIN2=$(curl -sf -X POST "${BASE_URL}/api/v1/auth/login" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${EMAIL2}&password=${PASS1}" 2>/dev/null) || { fail "Login user2 failed"; LOGIN2="{}"; }
TOKEN2=$(echo "$LOGIN2" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
assert_not_empty "Login user2 - got token" "$TOKEN2"

# Bad password should 401
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/auth/login" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${EMAIL1}&password=wrongpassword")
assert_http "Login with wrong password rejected" "$HTTP_CODE" "401"

# GET /me
ME=$(req_auth GET /api/v1/auth/me 2>/dev/null) || { fail "GET /me failed"; ME="{}"; }
ACCOUNT1=$(echo "$ME" | python3 -c "import sys,json; print(json.load(sys.stdin).get('account_number',''))" 2>/dev/null || echo "")
assert_not_empty "GET /me - got account_number" "$ACCOUNT1"

ME2=$(req_auth2 GET /api/v1/auth/me 2>/dev/null) || { fail "GET /me user2 failed"; ME2="{}"; }
ACCOUNT2=$(echo "$ME2" | python3 -c "import sys,json; print(json.load(sys.stdin).get('account_number',''))" 2>/dev/null || echo "")
assert_not_empty "GET /me user2 - got account_number" "$ACCOUNT2"

# Unauthenticated /me should 401
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api/v1/auth/me")
assert_http "Unauthenticated /me rejected" "$HTTP_CODE" "401"

#  2. Wallet 
log "2. Wallet — balances"

BALANCES=$(req_auth GET /api/v1/wallet/balances 2>/dev/null) || { fail "GET /balances failed"; BALANCES="[]"; }
WALLET_COUNT=$(echo "$BALANCES" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
if [[ "$WALLET_COUNT" -ge 3 ]]; then
  ok "Wallets initialised on register (got $WALLET_COUNT wallets)"
else
  fail "Expected at least 3 wallets after register, got $WALLET_COUNT"
fi

# Unauthenticated balances should 401
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api/v1/wallet/balances")
assert_http "Unauthenticated /balances rejected" "$HTTP_CODE" "401"

#  3. Rates 
log "3. Conversion rates"

RATES=$(req GET /api/v1/conversions/rates 2>/dev/null) || { fail "GET /rates failed"; RATES="{}"; }
EUR_RATE=$(echo "$RATES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('EUR/USD',''))" 2>/dev/null || echo "")
assert_not_empty "GET /rates - EUR/USD present" "$EUR_RATE"
GBP_RATE=$(echo "$RATES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('GBP/USD',''))" 2>/dev/null || echo "")
assert_not_empty "GET /rates - GBP/USD present" "$GBP_RATE"

#  4. Conversions 
log "4. Conversions — create & list"

IDEMPOTENCY_KEY="smoke-conv-${TS}"
CONV=$(req_auth POST /api/v1/conversions \
  -d "{\"from_currency\":\"USD\",\"to_currency\":\"EUR\",\"amount\":\"100\",\"idempotency_key\":\"${IDEMPOTENCY_KEY}\"}" \
  2>/dev/null) || { fail "POST /conversions failed"; CONV="{}"; }

CONV_ID=$(echo "$CONV" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
assert_not_empty "Create conversion - got id" "$CONV_ID"
assert_field "Create conversion" "$CONV" "from_currency" "USD"
assert_field "Create conversion" "$CONV" "to_currency" "EUR"
assert_field "Create conversion" "$CONV" "status" "COMPLETED"

# Idempotency — same key returns same record
CONV2=$(req_auth POST /api/v1/conversions \
  -d "{\"from_currency\":\"USD\",\"to_currency\":\"EUR\",\"amount\":\"100\",\"idempotency_key\":\"${IDEMPOTENCY_KEY}\"}" \
  2>/dev/null) || { fail "Idempotent conversion failed"; CONV2="{}"; }
CONV2_ID=$(echo "$CONV2" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [[ "$CONV_ID" == "$CONV2_ID" ]]; then
  ok "Conversion idempotency - same id returned"
else
  fail "Conversion idempotency - different ids: $CONV_ID vs $CONV2_ID"
fi

# List conversions
CONV_LIST=$(req_auth GET /api/v1/conversions 2>/dev/null) || { fail "GET /conversions failed"; CONV_LIST="[]"; }
CONV_LIST_COUNT=$(echo "$CONV_LIST" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
if [[ "$CONV_LIST_COUNT" -ge 1 ]]; then
  ok "GET /conversions - returned $CONV_LIST_COUNT records"
else
  fail "GET /conversions - expected at least 1 record, got $CONV_LIST_COUNT"
fi

#  5. Recipient lookup 
log "5. Recipient lookup"

LOOKUP=$(req_auth GET "/api/v1/wallet/lookup/${ACCOUNT2}" 2>/dev/null) || { fail "Lookup user2 failed"; LOOKUP="{}"; }
LOOKUP_EMAIL=$(echo "$LOOKUP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('email',''))" 2>/dev/null || echo "")
if [[ "$LOOKUP_EMAIL" == "$EMAIL2" ]]; then
  ok "Lookup by account number - returned correct email"
else
  fail "Lookup by account number - expected $EMAIL2, got $LOOKUP_EMAIL"
fi

# Lookup non-existent account should 404
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "${BASE_URL}/api/v1/wallet/lookup/9999-9999-9999")
assert_http "Lookup non-existent account" "$HTTP_CODE" "404"

#  6. P2P Transfer 
log "6. P2P Transfer — send money"

TRANSFER_KEY="smoke-transfer-${TS}"
TRANSFER=$(req_auth POST /api/v1/withdrawals/transfer \
  -d "{\"to_account_number\":\"${ACCOUNT2}\",\"currency\":\"USD\",\"amount\":\"10\",\"idempotency_key\":\"${TRANSFER_KEY}\"}" \
  2>/dev/null) || { fail "POST /withdrawals/transfer failed"; TRANSFER="{}"; }

TRANSFER_ID=$(echo "$TRANSFER" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
assert_not_empty "Create transfer - got id" "$TRANSFER_ID"
assert_field "Create transfer" "$TRANSFER" "currency" "USD"

# Idempotency
TRANSFER2=$(req_auth POST /api/v1/withdrawals/transfer \
  -d "{\"to_account_number\":\"${ACCOUNT2}\",\"currency\":\"USD\",\"amount\":\"10\",\"idempotency_key\":\"${TRANSFER_KEY}\"}" \
  2>/dev/null) || { fail "Idempotent transfer failed"; TRANSFER2="{}"; }
TRANSFER2_ID=$(echo "$TRANSFER2" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [[ "$TRANSFER_ID" == "$TRANSFER2_ID" ]]; then
  ok "Transfer idempotency - same id returned"
else
  fail "Transfer idempotency - different ids: $TRANSFER_ID vs $TRANSFER2_ID"
fi

# Self-transfer should be rejected
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${BASE_URL}/api/v1/withdrawals/transfer" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d "{\"to_account_number\":\"${ACCOUNT1}\",\"currency\":\"USD\",\"amount\":\"10\",\"idempotency_key\":\"smoke-self-${TS}\"}")
assert_http "Self-transfer rejected" "$HTTP_CODE" "400"

# List sent transfers
WD_LIST=$(req_auth GET /api/v1/withdrawals 2>/dev/null) || { fail "GET /withdrawals failed"; WD_LIST="[]"; }
WD_COUNT=$(echo "$WD_LIST" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
if [[ "$WD_COUNT" -ge 1 ]]; then
  ok "GET /withdrawals - returned $WD_COUNT records"
else
  fail "GET /withdrawals - expected at least 1 record"
fi

# List received transfers for user 2
RECV=$(req_auth2 GET /api/v1/withdrawals/received 2>/dev/null) || { fail "GET /withdrawals/received failed"; RECV="[]"; }
RECV_COUNT=$(echo "$RECV" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
if [[ "$RECV_COUNT" -ge 1 ]]; then
  ok "GET /withdrawals/received - user2 sees $RECV_COUNT received transfer(s)"
else
  fail "GET /withdrawals/received - user2 expected at least 1 received transfer"
fi

#  Balance changes
log "7. Balance verification after transfer"

# Wait briefly for wallet-consumer to process the SQS event
sleep 5

BALANCES2=$(req_auth2 GET /api/v1/wallet/balances 2>/dev/null) || { fail "GET /balances user2 failed"; BALANCES2="[]"; }
USD_BAL=$(echo "$BALANCES2" | python3 -c "
import sys, json
wallets = json.load(sys.stdin)
usd = next((w for w in wallets if w['currency'] == 'USD'), None)
print(usd['balance'] if usd else '')
" 2>/dev/null || echo "")

if [[ -n "$USD_BAL" ]] && python3 -c "import sys; exit(0 if float('$USD_BAL') > 0 else 1)" 2>/dev/null; then
  ok "User2 USD balance is positive after receiving transfer ($USD_BAL)"
else
  fail "User2 USD balance not positive after transfer (got '$USD_BAL') — wallet-consumer may still be processing"
fi

#  8. Security 
log "8. Security — token validation"

# Invalid token should 401
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer invalid.token.here" \
  "${BASE_URL}/api/v1/wallet/balances")
assert_http "Invalid token rejected" "$HTTP_CODE" "401"

# No token should 401
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "${BASE_URL}/api/v1/wallet/balances")
assert_http "Missing token rejected" "$HTTP_CODE" "401"

#  Summary 
echo ""
echo "═══════════════════════════════════════════════════════"
echo -e "  Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}"
echo "═══════════════════════════════════════════════════════"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo ""
  echo -e "${RED}Failures:${NC}"
  for err in "${ERRORS[@]}"; do
    echo -e "  ${RED}• $err${NC}"
  done
fi

echo ""

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi