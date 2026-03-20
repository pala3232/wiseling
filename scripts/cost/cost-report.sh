#!/usr/bin/env bash
# cost-report.sh — AWS cost summary for Wiseling
# Usage: ./cost-report.sh [--months N] [--days N] [--region REGION]
#   --months N      How many past months to show in the monthly view (default: 6)
#   --days N        How many past days to show in the daily view (default: 30)
#   --region REGION AWS region to scan live resources in (default: ap-southeast-2)
# Requires: aws CLI configured, Cost Explorer enabled (~$0.01/request)
# Section [5] also requires: jq  (winget install jqlang.jq  /  brew install jq  /  apt install jq)

set -euo pipefail

MONTHS=6
DAYS=30
REGION="${REGION:-ap-southeast-2}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --months) MONTHS="$2";  shift 2 ;;
    --days)   DAYS="$2";    shift 2 ;;
    --region) REGION="$2";  shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

TODAY=$(date +%Y-%m-%d)
MTD_START=$(date +%Y-%m-01)
MONTHLY_START=$(date -d "-${MONTHS} months" +%Y-%m-01 2>/dev/null || date -v-"${MONTHS}"m -v1d +%Y-%m-%d)
DAILY_START=$(date -d "-${DAYS} days" +%Y-%m-%d 2>/dev/null || date -v-"${DAYS}"d +%Y-%m-%d)
NEXT_MONTH=$(date -d "+1 month" +%Y-%m-01 2>/dev/null || date -v+1m -v1d +%Y-%m-%d)

echo "============================================"
echo "  Wiseling AWS Cost Report"
echo "  Run at : ${TODAY}  |  Region: ${REGION}"
echo "============================================"
echo ""

# ── [1] Monthly costs — one row per calendar month ───────────────────────────
echo ">>> [1] Monthly costs (last ${MONTHS} months)"
aws ce get-cost-and-usage \
  --time-period Start="${MONTHLY_START}",End="${TODAY}" \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --query 'ResultsByTime[*].{Month:TimePeriod.Start,Total_USD:Total.UnblendedCost.Amount,Estimated:Estimated}' \
  --output table

echo ""

# ── [2] Monthly costs broken down by service ──────────────────────────────────
echo ">>> [2] Monthly cost by service (last ${MONTHS} months, most recent month)"
aws ce get-cost-and-usage \
  --time-period Start="${MTD_START}",End="${TODAY}" \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount!=`"0"`].{Service:Keys[0],Cost_USD:Metrics.UnblendedCost.Amount}' \
  --output table

echo ""

# ── [3] Daily costs — one row per day ─────────────────────────────────────────
echo ">>> [3] Daily costs (last ${DAYS} days)"
aws ce get-cost-and-usage \
  --time-period Start="${DAILY_START}",End="${TODAY}" \
  --granularity DAILY \
  --metrics "UnblendedCost" \
  --query 'ResultsByTime[*].{Date:TimePeriod.Start,Total_USD:Total.UnblendedCost.Amount,Estimated:Estimated}' \
  --output table

echo ""

# ── [4] Daily costs broken down by service (current month) ───────────────────
echo ">>> [4] Daily cost by service (current month: ${MTD_START} → ${TODAY})"
aws ce get-cost-and-usage \
  --time-period Start="${MTD_START}",End="${TODAY}" \
  --granularity DAILY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --output text \
  --query 'ResultsByTime[*].[TimePeriod.Start, Groups[*].[Keys[0], Metrics.UnblendedCost.Amount][]]' | \
awk '
  NF == 1 { date = $1; next }
  NF >= 2 {
    cost = $NF
    svc  = ""
    for (i = 1; i < NF; i++) svc = svc (i > 1 ? " " : "") $i
    if (cost + 0 > 0) printf "  %-12s  %-45s  $%.4f\n", date, svc, cost
  }
'

echo ""

# ── [5] Cost projection — scan live resources × on-demand pricing ─────────────
# Queries currently running EC2, RDS, EKS, NAT Gateways, and ALBs, then prices
# each resource using the AWS Pricing API. No historical spend data needed.
echo ">>> [5] Cost projection — live resources × on-demand pricing"
echo "    Region: ${REGION}"
echo ""

if ! command -v jq &>/dev/null; then
  echo "  jq is required for cost projection. Install it first:"
  echo "    Windows (Git Bash):  winget install jqlang.jq"
  echo "    Linux/WSL:           sudo apt install jq"
  echo "    macOS:               brew install jq"
  echo ""
else
  # Fetch on-demand hourly price for an EC2 instance type
  get_ec2_price() {
    local itype="$1"
    aws pricing get-products \
      --service-code AmazonEC2 \
      --region us-east-1 \
      --filters \
        "Type=TERM_MATCH,Field=instanceType,Value=${itype}" \
        "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
        "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
        "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
        "Type=TERM_MATCH,Field=capacityStatus,Value=Used" \
        "Type=TERM_MATCH,Field=regionCode,Value=${REGION}" \
      --output text \
      --query 'PriceList[0]' 2>/dev/null \
    | jq -r '.terms.OnDemand | to_entries[0].value.priceDimensions | to_entries[0].value.pricePerUnit.USD // "0"' 2>/dev/null \
    || echo "0"
  }

  # Fetch on-demand hourly price for an RDS instance class (PostgreSQL, Single-AZ)
  get_rds_price() {
    local db_class="$1"
    aws pricing get-products \
      --service-code AmazonRDS \
      --region us-east-1 \
      --filters \
        "Type=TERM_MATCH,Field=instanceType,Value=${db_class}" \
        "Type=TERM_MATCH,Field=databaseEngine,Value=PostgreSQL" \
        "Type=TERM_MATCH,Field=deploymentOption,Value=Single-AZ" \
        "Type=TERM_MATCH,Field=regionCode,Value=${REGION}" \
      --output text \
      --query 'PriceList[0]' 2>/dev/null \
    | jq -r '.terms.OnDemand | to_entries[0].value.priceDimensions | to_entries[0].value.pricePerUnit.USD // "0"' 2>/dev/null \
    || echo "0"
  }

  TOTAL_HOURLY=0

  # Print one row and accumulate total
  print_row() {
    local label="$1" type="$2" count="$3" unit_hourly="$4"
    local subtotal; subtotal=$(awk "BEGIN {printf \"%.6f\", ${unit_hourly} * ${count}}")
    local per_24h;  per_24h=$(awk  "BEGIN {printf \"%.2f\",  ${subtotal} * 24}")
    local per_30d;  per_30d=$(awk  "BEGIN {printf \"%.2f\",  ${subtotal} * 24 * 30}")
    printf "  %-36s  %-22s  %3s  \$%-8s  \$%-10s  \$%s\n" \
      "${label}" "${type}" "${count}" \
      "$(awk "BEGIN {printf \"%.4f\", ${subtotal}}")" "${per_24h}" "${per_30d}"
    TOTAL_HOURLY=$(awk "BEGIN {printf \"%.6f\", ${TOTAL_HOURLY} + ${subtotal}}")
  }

  printf "  %-36s  %-22s  %3s  %-9s  %-11s  %s\n" "Resource" "Type" "Qty" "\$/hr" "\$/24h" "\$/30d"
  printf "  %-36s  %-22s  %3s  %-9s  %-11s  %s\n" "--------" "----" "---" "----" "-----" "-----"

  # EKS control plane — $0.10/hr flat per cluster
  eks_count=$(aws eks list-clusters --region "${REGION}" \
    --query 'length(clusters)' --output text 2>/dev/null || echo 0)
  [[ "${eks_count:-0}" -gt 0 ]] && print_row "EKS control plane" "managed cluster" "${eks_count}" "0.10"

  # EC2 running instances — grouped by instance type (one Pricing API call per unique type)
  declare -A ec2_counts=()
  while IFS= read -r itype; do
    [[ -z "${itype}" ]] && continue
    ec2_counts["${itype}"]=$(( ${ec2_counts["${itype}"]:-0} + 1 ))
  done < <(aws ec2 describe-instances \
    --region "${REGION}" \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].InstanceType' \
    --output text 2>/dev/null | tr '\t' '\n')
  for itype in "${!ec2_counts[@]}"; do
    price=$(get_ec2_price "${itype}")
    print_row "EC2" "${itype}" "${ec2_counts[$itype]}" "${price}"
  done

  # RDS instances — grouped by instance class
  declare -A rds_counts=()
  while IFS= read -r db_class; do
    [[ -z "${db_class}" ]] && continue
    rds_counts["${db_class}"]=$(( ${rds_counts["${db_class}"]:-0} + 1 ))
  done < <(aws rds describe-db-instances \
    --region "${REGION}" \
    --query 'DBInstances[?DBInstanceStatus==`available`].DBInstanceClass' \
    --output text 2>/dev/null | tr '\t' '\n')
  for db_class in "${!rds_counts[@]}"; do
    price=$(get_rds_price "${db_class}")
    print_row "RDS (PostgreSQL)" "${db_class}" "${rds_counts[$db_class]}" "${price}"
  done

  # NAT Gateways — $0.059/hr (ap-southeast-2 on-demand, Pricing API doesn't surface this cleanly)
  nat_count=$(aws ec2 describe-nat-gateways \
    --region "${REGION}" \
    --filter "Name=state,Values=available" \
    --query 'length(NatGateways)' --output text 2>/dev/null || echo 0)
  [[ "${nat_count:-0}" -gt 0 ]] && print_row "NAT Gateway" "per gateway" "${nat_count}" "0.059"

  # ALBs — $0.008/hr base rate (excludes LCU charges)
  alb_count=$(aws elbv2 describe-load-balancers \
    --region "${REGION}" \
    --query 'length(LoadBalancers[?Type==`application` && State.Code==`active`])' \
    --output text 2>/dev/null || echo 0)
  [[ "${alb_count:-0}" -gt 0 ]] && print_row "ALB (base, excl. LCU)" "application" "${alb_count}" "0.008"

  # Totals
  total_24h=$(awk "BEGIN {printf \"%.2f\", ${TOTAL_HOURLY} * 24}")
  total_30d=$(awk "BEGIN {printf \"%.2f\", ${TOTAL_HOURLY} * 24 * 30}")
  printf "  %-36s  %-22s  %3s  %-9s  %-11s  %s\n" "--------" "----" "---" "----" "-----" "-----"
  printf "  %-36s  %-22s  %3s  \$%-8s  \$%-10s  \$%s\n" \
    "TOTAL" "" "" "$(awk "BEGIN {printf \"%.4f\", ${TOTAL_HOURLY}}")" "${total_24h}" "${total_30d}"

  echo ""
  echo "  Prices: EC2/RDS via AWS Pricing API (on-demand, Linux, ${REGION})."
  echo "  NAT Gateway (\$0.059/hr) and ALB base (\$0.008/hr) are hardcoded region rates."
  echo "  Excludes: data transfer, SQS/DynamoDB requests, EBS storage, Karpenter spot nodes."
fi

echo ""
echo "============================================"
echo "  Cost Explorer API charges ~\$0.01/request."
echo "============================================"
