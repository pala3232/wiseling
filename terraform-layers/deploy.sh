#!/usr/bin/env bash
# usage is ./deploy.sh
# env vars:
#   TF_VAR_admin_iam_arn   IAM user/role ARN for kubectl access
#   TF_VAR_db_password     RDS master password

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYERS_DIR="$SCRIPT_DIR"

run_layer() {
  local layer="$1"
  echo ""
  echo "══════════════════════════════════════════"
  echo "  Applying layer: $layer"
  echo "══════════════════════════════════════════"
  cd "$LAYERS_DIR/$layer"
  terraform init -reconfigure
  terraform apply -auto-approve
}

# apply order: network -> data -> eks -> iam
# (IAM needs EKS OIDC ARN, so EKS must come before IAM)
run_layer "01-network"
run_layer "02-data"
run_layer "04-eks"
run_layer "03-iam"

echo ""
echo "✓ All layers applied."
