#!/bin/bash

# List of roles to clean up
ROLES=("pod-role" "wiseling-karpenter-role")

# List of policies to clean up
POLICIES=(
  "cloudwatch-policy"
  "dynamodb-policy"
  "wiseling-karpenter-policy"
  "AWSLoadBalancerControllerPolicy"
  "external-secrets-read-secret"
  "wiseling-sqs-policy"
)

ACCOUNT_ID=359707702022

# Detach policies from roles
for role in "${ROLES[@]}"; do
  echo "Detaching policies from role: $role"
  attached_policies=$(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text)
  for policy_arn in $attached_policies; do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$policy_arn"
  done
done

# Delete non-default policy versions
for policy in "${POLICIES[@]}"; do
  policy_arn="arn:aws:iam::$ACCOUNT_ID:policy/$policy"
  echo "Deleting non-default versions for policy: $policy"
  versions=$(aws iam list-policy-versions --policy-arn "$policy_arn" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)
  for version in $versions; do
    aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$version"
  done
done

# Delete policies
for policy in "${POLICIES[@]}"; do
  policy_arn="arn:aws:iam::$ACCOUNT_ID:policy/$policy"
  echo "Deleting policy: $policy"
  aws iam delete-policy --policy-arn "$policy_arn"
done

# Delete roles
for role in "${ROLES[@]}"; do
  echo "Deleting role: $role"
  aws iam delete-role --role-name "$role"
done

echo "IAM cleanup complete."