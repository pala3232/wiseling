# Wiseling — Terraform Layers

## Structure

```
terraform/layers/
├── 01-network/   VPC, subnets, route tables, security groups
├── 02-data/      RDS, SQS, DynamoDB, ECR (prevent_destroy), JWT secret
├── 03-iam/       IRSA pod-role, Karpenter role, all IAM policies
├── 04-eks/       EKS cluster, node group, OIDC provider
├── deploy.sh     Apply all layers in order
└── destroy.sh    Destroy all layers in reverse (or destroy a single layer)
```

## Apply order

```
01-network → 02-data → 04-eks → 03-iam
```

IAM (03) depends on EKS (04) for the OIDC provider ARN — this is intentional.

## Destroy order

```
03-iam → 04-eks → 02-data → 01-network
```

The destroy script automatically drains Karpenter nodes before destroying EKS,
which is the permanent fix for orphaned nodes on destroy.

## Usage

```bash
# Set required env vars
export TF_VAR_admin_iam_arn="arn:aws:iam::359707702022:user/your-user"
export TF_VAR_db_password="your-db-password"

# Apply everything
./deploy.sh

# Destroy everything (drains Karpenter nodes first)
./destroy.sh

# Destroy only EKS (e.g. to rebuild the cluster)
./destroy.sh 04-eks

# Re-apply only EKS
cd 04-eks && terraform init && terraform apply
```

## ECR repos

ECR repos have `prevent_destroy = true` — they survive `terraform destroy` on
layer 02. To actually delete them you must remove the lifecycle block first.
