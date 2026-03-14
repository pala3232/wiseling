#!/usr/bin/env bash
# usage: ./destroy.sh [layer]
# examples:
#   ./destroy.sh            destroys all layers in reverse order
#   ./destroy.sh 04-eks     destroys only the EKS layer
#
# env vars:
#   TF_VAR_admin_iam_arn
#   TF_VAR_db_password

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYERS_DIR="$SCRIPT_DIR"

destroy_layer() {
  local layer="$1"
  echo ""
  echo "══════════════════════════════════════════"
  echo "  Destroying layer: $layer"
  echo "══════════════════════════════════════════"
  cd "$LAYERS_DIR/$layer"
  terraform init -reconfigure
  terraform destroy -auto-approve
}

# if a specific layer is passed, destroy only that one
if [[ $# -gt 0 ]]; then
  destroy_layer "$1"
  echo ""
  echo "✓ Layer $1 destroyed."
  exit 0
fi

# before destroying EKS, drain all Karpenter nodes so they terminate cleanly
echo ""
echo "── Pre-destroy: draining Karpenter nodes ──"
KARPENTER_NODES=$(kubectl get nodes -l karpenter.sh/provisioner-name --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true)
if [[ -n "$KARPENTER_NODES" ]]; then
  echo "$KARPENTER_NODES" | xargs -I{} kubectl drain {} --ignore-daemonsets --delete-emptydir-data --force --timeout=120s || true
  echo "$KARPENTER_NODES" | xargs -I{} kubectl delete node {} || true
  echo "Waiting 30s for node termination..."
  sleep 30
else
  echo "No Karpenter nodes found."
fi

# destroy order: iam -> eks -> data -> network
destroy_layer "03-iam"
destroy_layer "04-eks"
destroy_layer "02-data"
destroy_layer "01-network"

echo ""
echo "✓ All layers destroyed."
