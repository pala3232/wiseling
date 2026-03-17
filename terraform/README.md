# Wiseling DR — Active-Passive Multi-Region

## Architecture

```
                    ┌─────────────────┐
                    │   Route 53      │
                    │  Health Check   │
                    │  Failover DNS   │
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              │ PRIMARY (healthy)            │ DR (standby)
              ▼                             ▼
   ap-southeast-2 (Sydney)        ap-southeast-1 (Singapore)
   ┌─────────────────────┐        ┌─────────────────────┐
   │ EKS + ALB           │        │ EKS + ALB           │
   │ RDS Primary         │───────▶│ RDS Read Replica    │
   │ DynamoDB (global)   │        │ DynamoDB (replicated)│
   │ SQS                 │        │ SQS (cross-region)  │
   └─────────────────────┘        └─────────────────────┘
```

## Failover flow

1. Primary ALB health check fails 3 consecutive times (90s)
2. Route 53 automatically switches DNS to Singapore ALB
3. **Manual trigger**: run the `Failover to Singapore (DR)` workflow
4. Workflow promotes read replica → standalone writable RDS
5. Updates Secrets Manager with new endpoint
6. Restarts pods to pick up new DB credentials
7. Smoke tests confirm DR is serving traffic

RTO: ~5-8 minutes (promotion ~3-5min + pod restart ~1-2min)
RPO: replication lag at time of failure (typically <1 minute)

## Layer apply order

```bash
# DR layers (run after primary layers are up)
cd terraform/layers/01-network-sgp && terraform init && terraform apply
cd terraform/layers/02-data-sgp    && terraform init && terraform apply
cd terraform/layers/04-eks-sgp     && terraform init && terraform apply
cd terraform/layers/03-iam-sgp     && terraform init && terraform apply

# Global layer (run last — needs both ALB DNS names)
cd terraform/layers/05-global      && terraform init && terraform apply \
  -var="domain_name=yourdomain.xyz" \
  -var="primary_alb_dns=<your-sydney-alb-dns>" \
  -var="dr_alb_dns=<your-singapore-alb-dns>"
```

## Before applying 05-global

Get your ALB DNS names:
```bash
# Primary (Sydney)
aws eks update-kubeconfig --name wiseling-eks-cluster --region ap-southeast-2
kubectl get ingress wiseling-ingress -n wiseling -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# DR (Singapore)
aws eks update-kubeconfig --name wiseling-eks-cluster-sgp --region ap-southeast-1
kubectl get ingress wiseling-ingress -n wiseling -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

## After applying 05-global

Get the Route 53 nameservers:
```bash
cd terraform/layers/05-global
terraform output name_servers
```

Paste these 4 NS records into Cloudflare as custom nameservers for your domain.
Wait ~2 hours for propagation, then verify at whatsmydns.net.

## Required GitHub secrets

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | existing |
| `AWS_SECRET_ACCESS_KEY` | existing |
| `DB_PASSWORD` | your RDS password |
| `ADMIN_IAM_ARN` | your IAM user ARN |

## Required patch to primary 02-data layer

See `PATCH-02-data-outputs.tf` — add those outputs to your existing
`terraform/layers/02-data/outputs.tf` before applying 02-data-sgp.
The Singapore replica needs the primary RDS ARN from remote state.

## Notes

- DynamoDB is already globally replicated to ap-southeast-1 (you set this up)
- SQS queues live in ap-southeast-2 only — DR pods connect cross-region
- After failover, the promoted RDS is standalone — replication is broken
- To restore: rebuild primary, set up replication again, fail back manually
- The DR cluster runs a single t3.large node — scale up via Karpenter after failover
