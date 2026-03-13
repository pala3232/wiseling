#!/bin/bash
# Script to import existing ECR repositories into Terraform state
# Run from your terraform/ directory (where your main.tf is)

set -e

REPOS=(
  "frontend"
)

for repo in "${REPOS[@]}"; do
  echo "Importing ECR repo: $repo"
  terraform import \
    'module.create_registry.aws_ecr_repository.wiseling-ecr-repo["'$repo'"]' \
    wiseling/$repo
  echo "---"
done

echo "All ECR repositories imported. Run 'terraform plan' to verify state."
