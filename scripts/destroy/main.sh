#!/bin/bash
set -e

CLUSTER_NAME="wiseling-eks-cluster"
REGION="ap-southeast-2"

echo "Configuring kubectl..."
aws eks update-kubeconfig \
  --name $CLUSTER_NAME \
  --region $REGION

echo "Deleting all K8s resources..."
kubectl delete namespace wiseling
kubectl delete namespace karpenter

echo "Deleting ingress (removes ALB)..."
kubectl delete ingress wiseling-ingress -n wiseling --ignore-not-found

echo "Waiting for ALB to be deleted..."
sleep 60

echo "Destroying Terraform..."
cd terraform/create-sqs && terraform destroy -auto-approve && cd ../..
cd terraform/iam/irsa && terraform destroy -auto-approve && cd ../..
cd terraform/create-eks && terraform destroy -auto-approve && cd ../..
cd terraform/create-rds && terraform destroy -auto-approve && cd ../..
cd terraform/main-vpc && terraform destroy -auto-approve && cd ../..

echo "Done!"