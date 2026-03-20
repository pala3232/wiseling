#!/usr/bin/env bash
# cost-report.sh — AWS cost projection for Wiseling (manifest-based)
# Usage: ./cost-report.sh
# Requires: jq  (winget install jqlang.jq  /  brew install jq  /  apt install jq)

set -euo pipefail

TODAY=$(date +%Y-%m-%d)

echo "============================================"
echo "  Wiseling AWS Cost Report"
echo "  Run at : ${TODAY}"
echo "============================================"
echo ""

# ── Cost projection — from infra manifest (no deployment needed) ──────────
# Reads scripts/cost/infra-manifest.conf, prices each resource via the AWS
# Pricing API, and projects to 24h and 30 days.
# Edit the manifest to match your infra. No resources need to be running.
MANIFEST_FILE="$(dirname "$0")/infra-manifest.conf"

echo ">>> Cost projection — from infra manifest"
echo "    Manifest: ${MANIFEST_FILE}"
echo ""

if [[ ! -f "${MANIFEST_FILE}" ]]; then
  echo "  Manifest not found: ${MANIFEST_FILE}"
  echo "  Expected at scripts/cost/infra-manifest.conf"
elif ! command -v jq &>/dev/null; then
  echo "  jq is required for cost projection. Install it first:"
  echo "    Windows (Git Bash):  winget install jqlang.jq"
  echo "    Linux/WSL:           sudo apt install jq"
  echo "    macOS:               brew install jq"
else
  # Pricing API is us-east-1 only
  get_ec2_price() {
    local itype="$1" region="$2"
    aws pricing get-products \
      --service-code AmazonEC2 \
      --region us-east-1 \
      --filters \
        "Type=TERM_MATCH,Field=instanceType,Value=${itype}" \
        "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
        "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
        "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
        "Type=TERM_MATCH,Field=capacityStatus,Value=Used" \
        "Type=TERM_MATCH,Field=regionCode,Value=${region}" \
      --output text --query 'PriceList[0]' 2>/dev/null \
    | jq -r '.terms.OnDemand | to_entries[0].value.priceDimensions | to_entries[0].value.pricePerUnit.USD // "0"' 2>/dev/null \
    || echo "0"
  }

  get_rds_price() {
    local db_class="$1" region="$2"
    aws pricing get-products \
      --service-code AmazonRDS \
      --region us-east-1 \
      --filters \
        "Type=TERM_MATCH,Field=instanceType,Value=${db_class}" \
        "Type=TERM_MATCH,Field=databaseEngine,Value=PostgreSQL" \
        "Type=TERM_MATCH,Field=deploymentOption,Value=Single-AZ" \
        "Type=TERM_MATCH,Field=regionCode,Value=${region}" \
      --output text --query 'PriceList[0]' 2>/dev/null \
    | jq -r '.terms.OnDemand | to_entries[0].value.priceDimensions | to_entries[0].value.pricePerUnit.USD // "0"' 2>/dev/null \
    || echo "0"
  }

  # On-demand hourly rates hardcoded for services the Pricing API doesn't surface cleanly.
  # Update if your regions differ: https://aws.amazon.com/vpc/pricing/
  nat_gateway_rate() {
    case "$1" in
      ap-southeast-1) echo "0.059" ;;
      ap-southeast-2) echo "0.059" ;;
      us-east-1)      echo "0.045" ;;
      us-west-2)      echo "0.045" ;;
      eu-west-1)      echo "0.048" ;;
      *)              echo "0.059" ;;  # default to Sydney rate
    esac
  }

  alb_rate() { echo "0.008"; }  # base hourly rate, excludes LCU
  route53_zone_rate() { echo "0.000694"; }  # $0.50/month flat per hosted zone
  route53_hc_rate() {
    case "$1" in
      fast) echo "0.001389" ;;  # $1.00/month (10s interval)
      *)    echo "0.000694" ;;  # $0.50/month (30s interval)
    esac
  }
  secretsmanager_secret_rate() { echo "0.000556"; }  # $0.40/month per secret
  cloudwatch_alarm_rate()       { echo "0.000139"; }  # $0.10/month per alarm
  dynamodb_global_table_rate()  { echo "0.001389"; }  # ~$1.00/month low estimate (PAY_PER_REQUEST + replica writes)

  TOTAL_HOURLY=0

  print_row() {
    local label="$1" spec="$2" count="$3" unit_hourly="$4" region="$5"
    local subtotal; subtotal=$(awk "BEGIN {printf \"%.6f\", ${unit_hourly} * ${count}}")
    local per_24h;  per_24h=$(awk  "BEGIN {printf \"%.2f\",  ${subtotal} * 24}")
    local per_30d;  per_30d=$(awk  "BEGIN {printf \"%.2f\",  ${subtotal} * 24 * 30}")
    printf "  %-34s  %-16s  %-14s  %3s  \$%-8s  \$%-10s  \$%s\n" \
      "${label}" "${spec}" "${region}" "${count}" \
      "$(awk "BEGIN {printf \"%.4f\", ${subtotal}}")" "${per_24h}" "${per_30d}"
    TOTAL_HOURLY=$(awk "BEGIN {printf \"%.6f\", ${TOTAL_HOURLY} + ${subtotal}}")
  }

  printf "  %-34s  %-16s  %-14s  %3s  %-9s  %-11s  %s\n" \
    "Resource" "Spec" "Region" "Qty" "\$/hr" "\$/24h" "\$/30d"
  printf "  %-34s  %-16s  %-14s  %3s  %-9s  %-11s  %s\n" \
    "--------" "----" "------" "---" "----" "-----" "-----"

  # Price cache to avoid duplicate Pricing API calls for the same type+region
  declare -A price_cache=()

  while IFS= read -r line; do
    # Strip comments and blank lines
    line="${line%%#*}"
    [[ -z "${line// }" ]] && continue

    read -r res_type count spec region label <<< "${line}"
    [[ -z "${res_type}" ]] && continue

    cache_key="${res_type}:${spec}:${region}"
    if [[ -z "${price_cache[$cache_key]+x}" ]]; then
      case "${res_type}" in
        eks_cluster) price_cache[$cache_key]="0.10" ;;
        ec2)         price_cache[$cache_key]=$(get_ec2_price "${spec}" "${region}") ;;
        rds)         price_cache[$cache_key]=$(get_rds_price "${spec}" "${region}") ;;
        nat_gateway)   price_cache[$cache_key]=$(nat_gateway_rate "${region}") ;;
        alb)           price_cache[$cache_key]=$(alb_rate) ;;
        route53_zone)          price_cache[$cache_key]=$(route53_zone_rate) ;;
        route53_hc)            price_cache[$cache_key]=$(route53_hc_rate "${spec}") ;;
        secretsmanager_secret) price_cache[$cache_key]=$(secretsmanager_secret_rate) ;;
        cloudwatch_alarm)      price_cache[$cache_key]=$(cloudwatch_alarm_rate) ;;
        dynamodb_global_table) price_cache[$cache_key]=$(dynamodb_global_table_rate) ;;
        *)           price_cache[$cache_key]="0" ;;
      esac
    fi

    price="${price_cache[$cache_key]}"
    display_spec="${spec//-/}"
    [[ "${spec}" == "-" ]] && display_spec="-"
    print_row "${label:-${res_type}}" "${display_spec}" "${count}" "${price}" "${region}"
  done < "${MANIFEST_FILE}"

  total_24h=$(awk "BEGIN {printf \"%.2f\", ${TOTAL_HOURLY} * 24}")
  total_30d=$(awk "BEGIN {printf \"%.2f\", ${TOTAL_HOURLY} * 24 * 30}")
  printf "  %-34s  %-16s  %-14s  %3s  %-9s  %-11s  %s\n" \
    "--------" "----" "------" "---" "----" "-----" "-----"
  printf "  %-34s  %-16s  %-14s  %3s  \$%-8s  \$%-10s  \$%s\n" \
    "TOTAL" "" "" "" "$(awk "BEGIN {printf \"%.4f\", ${TOTAL_HOURLY}}")" "${total_24h}" "${total_30d}"

  echo ""
  echo "  EC2/RDS prices from AWS Pricing API (on-demand, Linux)."
  echo "  NAT Gateway and ALB base rates are hardcoded — see nat_gateway_rate() to update."
  echo "  Excludes: data transfer, SQS/DynamoDB requests, EBS storage, Karpenter nodes."
  echo "  To include Karpenter nodes, uncomment the relevant lines in infra-manifest.conf."
fi
