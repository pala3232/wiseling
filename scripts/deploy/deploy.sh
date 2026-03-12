#!/bin/bash
set -e

CLUSTER_NAME="wiseling-eks-cluster"
REGION="ap-southeast-2"

echo "Configuring kubectl..."
aws eks update-kubeconfig \
  --name $CLUSTER_NAME \
  --region $REGION

echo "Adding helm repos..."
helm repo add eks https://aws.github.io/eks-charts
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

echo "creating irsa namespace and service account..."
kubectl apply -f ../../kubernetes-manifests/irsa/namespace.yaml
kubectl apply -f ../../kubernetes-manifests/irsa/sa.yaml

echo "Installing AWS Load Balancer Controller..."
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=wiseling-sa

echo "Waiting for LB controller to be ready..."
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s


echo "Creating karpenter namespace..."
kubectl create namespace karpenter --dry-run=client -o yaml | kubectl apply -f -

echo "Applying Karpenter service account..."
kubectl apply -f ../../kubernetes-manifests/karpenter/serviceaccount.yaml

echo "Installing Karpenter CRDs..."
helm upgrade --install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd \
  --namespace karpenter

echo "Installing Karpenter..."
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace karpenter \
  --set settings.clusterName=$CLUSTER_NAME \
  --set settings.interruptionQueue=wiseling-karpenter \
  --set serviceAccount.create=false \
  --set serviceAccount.name=karpenter-sa

echo "Waiting for EC2NodeClass CRD to be available..."
until kubectl get crd ec2nodeclasses.karpenter.k8s.aws >/dev/null 2>&1; do
  sleep 2
done

echo "Applying Karpenter EC2NodeClass..."
kubectl apply -f ../../kubernetes-manifests/karpenter/nodeclass.yaml

echo "Applying Karpenter node pool..."
kubectl apply -f ../../kubernetes-manifests/karpenter/nodepool.yaml

echo "Installing External Secrets Operator..."
helm upgrade --install external-secrets external-secrets/external-secrets -n kube-system

echo "Waiting for External Secrets to be ready..."
kubectl rollout status deployment/external-secrets -n kube-system --timeout=120s
kubectl rollout status deployment/external-secrets-webhook -n kube-system --timeout=120s

echo "Waiting for External Secrets CRDs to be ready..."
until kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; do
  sleep 2
done
until kubectl get crd clustersecretstores.external-secrets.io >/dev/null 2>&1; do
  sleep 2
done
echo "Giving API server time to sync CRDs..."
sleep 10

echo "Applying K8s manifests..."
kubectl apply -f ../../kubernetes-manifests/secrets/
kubectl apply -f ../../kubernetes-manifests/configmap/configmap.yaml
kubectl apply -f ../../kubernetes-manifests/secrets/
kubectl apply -f ../../kubernetes-manifests/auth-service/
kubectl apply -f ../../kubernetes-manifests/conversion-service/
kubectl apply -f ../../kubernetes-manifests/wallet-service/
kubectl apply -f ../../kubernetes-manifests/withdrawal-service/
kubectl apply -f ../../kubernetes-manifests/workers/
kubectl apply -f ../../kubernetes-manifests/ingress.yaml
kubectl apply -f ../../kubernetes-manifests/frontend-service/
kubectl apply -f ../../kubernetes-manifests/services

echo "Done!"