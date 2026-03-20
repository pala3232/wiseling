#!/bin/bash
set -euo pipefail

log() {
  echo -e "\033[1;34m[$(date '+%Y-%m-%d %H:%M:%S')] $*\033[0m"
}

error_handler() {
  echo -e "\033[1;31m[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Script failed at line $1.\033[0m" >&2
  exit 1
}
trap 'error_handler $LINENO' ERR

CLUSTER_NAME="wiseling-eks-cluster-sgp"
REGION="ap-southeast-1"


log "Syncing JWT secret to Singapore..."
JWT_VALUE=$(aws secretsmanager get-secret-value \
  --secret-id wiseling-jwt-secret-key \
  --region ap-southeast-2 \
  --query SecretString \
  --output text)
aws secretsmanager put-secret-value \
  --secret-id wiseling-jwt-secret-key-sgp \
  --secret-string "$JWT_VALUE" \
  --region "$REGION"


log "Configuring kubectl..."
aws eks update-kubeconfig \
  --name "$CLUSTER_NAME" \
  --region "$REGION"


log "Adding helm repos..."
helm repo add eks https://aws.github.io/eks-charts
helm repo add external-secrets https://charts.external-secrets.io
helm repo update


if [[ ! -f kubernetes-manifests-dr/irsa/namespace.yaml ]]; then
  log "ERROR: kubernetes-manifests-dr/irsa/namespace.yaml not found!"
  pwd
  ls -l kubernetes-manifests-dr/irsa/
  exit 1
fi
kubectl apply -f kubernetes-manifests-dr/irsa/namespace.yaml
kubectl apply -f kubernetes-manifests-dr/irsa/sa.yaml


log "Installing metrics-server (required for HPA)..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --set args[0]="--kubelet-preferred-address-types=InternalIP"


log "Installing AWS Load Balancer Controller..."
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=wiseling-sa


log "Waiting for LB controller to be ready..."
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s


log "Creating karpenter namespace..."
kubectl create namespace karpenter --dry-run=client -o yaml | kubectl apply -f -


log "Applying Karpenter service account..."
kubectl apply -f kubernetes-manifests-dr/karpenter/serviceaccount.yaml


log "Installing Karpenter CRDs..."
helm upgrade --install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd \
  --namespace karpenter


log "Installing Karpenter..."
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace karpenter \
  --set settings.clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=karpenter-sa \
  --set replicas=1


log "Waiting for EC2NodeClass CRD to be available..."
until kubectl get crd ec2nodeclasses.karpenter.k8s.aws >/dev/null 2>&1; do
  sleep 2
done


log "Applying Karpenter EC2NodeClass..."
kubectl apply -f kubernetes-manifests-dr/karpenter/nodeclass.yaml


log "Applying Karpenter node pool..."
kubectl apply -f kubernetes-manifests-dr/karpenter/nodepool.yaml


log "Installing External Secrets Operator..."
helm upgrade --install external-secrets external-secrets/external-secrets -n kube-system


log "Waiting for External Secrets to be ready..."
kubectl rollout status deployment/external-secrets -n kube-system --timeout=120s
kubectl rollout status deployment/external-secrets-webhook -n kube-system --timeout=120s


log "Waiting for External Secrets CRDs to be ready..."
until kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; do
  sleep 2
done
until kubectl get crd clustersecretstores.external-secrets.io >/dev/null 2>&1; do
  sleep 2
done
log "Giving API server time to sync CRDs..."
sleep 10


log "Applying K8s manifests..."
kubectl apply -f kubernetes-manifests-dr/secrets/
kubectl apply -f kubernetes-manifests-dr/configmap/configmap.yaml
kubectl apply -f kubernetes-manifests-dr/deployments/auth-service/
kubectl apply -f kubernetes-manifests-dr/deployments/conversion-service/
kubectl apply -f kubernetes-manifests-dr/deployments/wallet-service/
kubectl apply -f kubernetes-manifests-dr/deployments/withdrawal-service/
kubectl apply -f kubernetes-manifests-dr/deployments/workers/
kubectl apply -f kubernetes-manifests-dr/deployments/redis-service/
kubectl apply -f kubernetes-manifests-dr/ingress.yaml
kubectl apply -f kubernetes-manifests-dr/deployments/frontend-service/
kubectl apply -f kubernetes-manifests-dr/services/pod-services.yaml
kubectl apply -f kubernetes-manifests-dr/network-policies/
kubectl apply -f kubernetes-manifests-dr/deployments/hpa.yaml

log "Done!"
