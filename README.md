# Wiseling

Multi-currency wallet API with FX conversions and P2P transfers, built on AWS EKS with a microservices architecture and event-driven processing.

**Live region:** `ap-southeast-2` (Sydney) · **DR region:** `ap-southeast-1` (Singapore)

---

## Architecture

![Wiseling Infrastructure](images/wiseling-infra.png)

![Wiseling Event Flows](images/wiseling-eventflow.png)

### Services

| Service | Port | Responsibility |
|---|---|---|
| `auth-service` | 8000 | Register, login, JWT issuance, account number lookup |
| `wallet-service` | 8001 | Balances, ledger, recipient lookup |
| `conversion-service` | 8002 | FX conversions, live rates |
| `withdrawal-service` | 8003 | P2P transfers |
| `wallet-consumer` | - | SQS consumer, debits/credits/transfers |
| `conversion-outbox-poller` | - | Publishes conversion events to SQS |
| `withdrawal-outbox-poller` | - | Publishes transfer events to SQS |
| `conversion-dynamo-cleaner` | - | Cleans DynamoDB buffer after RDS recovery |
| `withdrawal-dynamo-cleaner` | - | Cleans DynamoDB buffer after RDS recovery |
| `wallet-reconciler` | - | Replays DynamoDB buffer on startup after failover |
| `frontend` | 80 | Single-page app served via nginx |

---

## Event Flows

### P2P Transfer

```
POST /api/v1/withdrawals/transfer
        │
        ▼
withdrawal-service
  ├── Resolves recipient via auth-service lookup
  ├── Writes Withdrawal record + OutboxEvent (atomic)
  └── Writes to DynamoDB buffer (DR safety net)
        │
        ▼
withdrawal-outbox-poller -> SQS (wiseling-withdrawals)
        │
        ▼
wallet-consumer
  ├── Debits sender wallet
  ├── Credits recipient wallet
  └── PATCH /internal/{id}/complete -> withdrawal-service
```

### FX Conversion

```
POST /api/v1/conversions
        │
        ▼
conversion-service
  ├── Writes Conversion record + OutboxEvent (atomic)
  └── Writes to DynamoDB buffer (DR safety net)
        │
        ▼
conversion-outbox-poller -> SQS (wiseling-conversions)
        │
        ▼
wallet-consumer
  ├── Debits from_currency wallet
  └── Credits to_currency wallet
```

---

## Infrastructure

### Terraform Layers - Primary (ap-southeast-2)

```
terraform/layers/
├── 01-network/   VPC, subnets, route tables, NAT gateway, security groups, VPC endpoint
├── 02-data/      RDS PostgreSQL, SQS + DLQs, DynamoDB global table, ECR repos, Secrets Manager
├── 03-iam/       IRSA pod role, Karpenter role, all IAM policies
├── 04-eks/       EKS cluster, bootstrap node group, OIDC provider, launch templates
├── deploy.sh     Apply all layers in order
└── destroy.sh    Destroy all layers in reverse (drains Karpenter nodes first)
```

**Apply order:** `01-network -> 02-data -> 04-eks -> 03-iam`

IAM (03) reads the OIDC provider ARN from EKS (04) state, so EKS must be applied before IAM.

**Destroy order:** `03-iam -> 04-eks -> 02-data -> 01-network`

ECR repositories have `prevent_destroy = true` and survive a full destroy.

### Terraform Layers - DR (ap-southeast-1)

```
terraform/layers-dr/
├── 01-network-sgp/   VPC, subnets, route tables, NAT gateway, security groups (Singapore)
├── 02-data-sgp/      RDS read replica, SQS queues, Secrets Manager mirrors
├── 03-iam-sgp/       IRSA pod role, Karpenter role, IAM policies (Singapore)
├── 04-eks-sgp/       EKS DR cluster, bootstrap node group, OIDC provider
└── 05-global/        Route 53 hosted zone, health checks, failover DNS records, ACM certificates
```

**Apply order:** `01-network-sgp -> 02-data-sgp -> 04-eks-sgp -> 03-iam-sgp -> 05-global`

### AWS Resources

| Resource | Name | Region |
|---|---|---|
| EKS Cluster (primary) | `wiseling-eks-cluster` | ap-southeast-2 |
| EKS Cluster (DR) | `wiseling-eks-cluster-sgp` | ap-southeast-1 |
| RDS PostgreSQL 16 (primary) | `wiseling-rds-instance` | ap-southeast-2 |
| RDS Read Replica (DR) | `wiseling-rds-replica-sgp` | ap-southeast-1 |
| SQS Queues | `wiseling-conversions`, `wiseling-withdrawals` | both regions |
| SQS DLQs | `wiseling-conversions-dlq`, `wiseling-withdrawals-dlq` | ap-southeast-2 |
| DynamoDB Global Table | `wiseling-outbox` (replicated to ap-southeast-1) | global |
| Route 53 Hosted Zone | `var.domain_name` with failover routing | global |
| ACM Certificates | Primary + DR | ap-southeast-2 / ap-southeast-1 |
| Secrets Manager | `wiseling/db-urls`, `wiseling-jwt-secret-key` | both regions |
| ECR | `wiseling/auth-service`, `wiseling/wallet-service`, `wiseling/conversion-service`, `wiseling/withdrawal-service`, `wiseling/frontend` | ap-southeast-2 |
| S3 State Backend | `wiseling-terraform-state-pala3105` | ap-southeast-2 |

### Disaster Recovery

- **DynamoDB Global Table** (`wiseling-outbox`) replicates outbox events to `ap-southeast-1` in real time.
- **RDS read replica** in Singapore is promoted to primary on failover.
- **Route 53 failover routing** with health checks on `/api/v1/auth/health` redirects traffic to the DR ALB when the primary health check fails.
- **`wallet-reconciler`** replays unprocessed DynamoDB events on DR cluster startup to restore wallet consistency.

---

## Kubernetes

- **Namespace:** `wiseling`
- **Node provisioning:** Karpenter (dynamic) + 1 bootstrap `t3.large` node
- **Secrets:** AWS Secrets Manager via External Secrets Operator
- **Ingress:** AWS Load Balancer Controller (internet-facing ALB)
- **Network policies:** Default deny-all ingress, per-service allow rules
- **Deployments:** Blue/green, separate manifests under `blue-deployments/` and `green-deployments/`

### Deployment Strategy

Blue/green switching is handled via the `switch-blue-green` workflow. The active colour is selected by updating the ingress target service. Pod Disruption Budgets (PDBs) and HPAs are configured per deployment colour.

---

## API Reference

All endpoints except `/api/v1/auth/register`, `/api/v1/auth/login`, and `/api/v1/conversions/rates` require `Authorization: Bearer <token>`.

### Auth - `POST /api/v1/auth/register`
```json
{ "email": "user@example.com", "password": "yourpassword" }
```
Returns `{ "id", "email", "account_number" }`. Creates 3 starter wallets (USD, EUR, GBP).

### Auth - `POST /api/v1/auth/login`
Form-encoded: `username=user@example.com&password=yourpassword`
Returns `{ "access_token", "token_type" }`.

### Auth - `GET /api/v1/auth/me`
Returns the current user including `account_number`.

### Wallet - `GET /api/v1/wallet/balances`
Returns an array of `{ "id", "currency", "balance" }`.

### Wallet - `GET /api/v1/wallet/lookup/{account_number}`
Resolves an account number to `{ "user_id", "email", "account_number" }`.

### Conversions - `POST /api/v1/conversions`
```json
{ "from_currency": "USD", "to_currency": "EUR", "amount": "100", "idempotency_key": "<uuid>" }
```
Fee: 0.30%. Status is `PENDING` immediately, wallet balances update asynchronously via SQS.

### Conversions - `GET /api/v1/conversions/rates`
Returns live FX rates, e.g. `{ "EUR/USD": "1.0889", "GBP/USD": "1.2763" }`.

### Transfers - `POST /api/v1/withdrawals/transfer`
```json
{ "to_account_number": "1234-5678-9012", "currency": "USD", "amount": "50", "idempotency_key": "<uuid>" }
```
Fee-free. Status updates to `COMPLETED` after `wallet-consumer` processes the SQS event.

### Transfers - `GET /api/v1/withdrawals`
Lists transfers sent by the current user.

### Transfers - `GET /api/v1/withdrawals/received`
Lists transfers received by the current user.

---

## Getting Started

### Prerequisites

- AWS CLI configured with sufficient IAM permissions
- `terraform >= 1.3.0`
- `kubectl`
- `helm`
- Docker

### Required GitHub Secrets

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `ADMIN_IAM_ARN` | Your IAM user/role ARN for kubectl access |
| `DB_PASSWORD` | RDS master password (8+ chars, no special characters) |
| `DOMAIN_NAME` | Domain name for Route 53 hosted zone and ACM certs (e.g. `wiseling.io`) |

> Before running any `build-push-deploy-*.yml` workflow, update the `ECR_REPO_URL` env var at the top of each file to point to your own ECR registry.

### Deploy - Primary Region

1. Run **Deploy Terraform Infrastructure** workflow
2. Run **Deploy Cluster** workflow — bootstraps the cluster, uploads the JWT secret, installs controllers and applies all manifests
3. Run **Deploy Observability Stack** workflow

### Deploy - DR Region

1. Run **Deploy Terraform Infrastructure (DR - Singapore)** workflow for layers `01-network-sgp` through `03-iam-sgp`
2. Run **Deploy Cluster DR** workflow
3. Run **Deploy Terraform Infrastructure (DR - Singapore)** workflow with layer `05-global` — outputs the Route 53 nameservers and both ACM certificate ARNs
4. Paste the nameservers into your domain provider and the ACM ARN annotations into both ingress YAMLs, then re-run **Deploy Cluster** and **Deploy Cluster DR**
5. In `terraform/layers-dr/05-global/main.tf` switch both health checks from `port 80 / HTTP` to `port 443 / HTTPS`, then re-run **Deploy Terraform Infrastructure (DR - Singapore)** with layer `05-global` — this updates the Route 53 health checks to validate over HTTPS using the provisioned ACM certificate, completing the failover DNS setup

### Destroy Infrastructure

Always destroy DR before primary — the DR RDS read replica depends on the primary RDS instance, so destroying primary first will fail.

1. Run **Destroy DR Terraform Infrastructure** workflow (requires typing `DESTROY` to confirm)
2. Run **Destroy Terraform Infrastructure** workflow (requires typing `DESTROY` to confirm)

Both workflows support targeting a specific layer via the layer input, or leave blank to destroy all in reverse order.

---

## CI/CD Pipelines

| Workflow | Trigger | Description |
|---|---|---|
| `build-push-*.yml` | Manual | Build service image and push to ECR (one workflow per service) |
| `deploy-infra.yml` | Manual | Apply one or all Terraform layers (primary) |
| `deploy-cluster.yml` | Manual | Bootstrap primary cluster |
| `deploy-cluster-dr.yml` | Manual | Bootstrap DR cluster |
| `deploy-infra-failover.yml` | Manual | Apply DR Terraform layers |
| `destroy-infra.yml` | Manual (requires `DESTROY`) | Destroy primary Terraform layers |
| `destroy-dr-infra.yml` | Manual (requires `DESTROY`) | Destroy DR Terraform layers |
| `deploy-observability.yml` | Manual | Install Prometheus + Grafana stack |
| `switch-blue-green.yml` | Manual | Switch active deployment colour |
| `failover.yml` | Manual | Trigger DR failover sequence |
| `smoke-tests.yml` | Manual | Run end-to-end smoke tests against live ALB |
| `deploy-wallet-consumer.yml` | Manual | Deploy wallet-consumer worker |
| `deploy-withdrawal-processor.yml` | Manual | Deploy withdrawal-processor worker |
| `deploy-conversion-outbox-poller.yml` | Manual | Deploy conversion-outbox-poller worker |
| `deploy-conversion-dynamo-cleaner.yml` | Manual | Deploy conversion-dynamo-cleaner worker |
| `deploy-withdrawal-dynamo-cleaner.yml` | Manual | Deploy withdrawal-dynamo-cleaner worker |

### Running Smoke Tests

Trigger the **Smoke Tests** workflow. It auto-resolves the ALB URL from the cluster. Tests cover:

- User registration and login
- Wallet initialisation (3 wallets on register)
- FX conversion creation and idempotency
- Recipient lookup by account number
- P2P transfer creation, idempotency, self-transfer rejection
- Balance verification after transfer
- Security (invalid and missing tokens)

---

## Local Development

Each service is a standalone FastAPI app. To run locally:

```bash
cd services/auth-service
pip install -e .
uvicorn app.main:app --reload --port 8000
```

Services read configuration from environment variables. See each service's `app/core/config.py` for the full list of required settings.

---

## Project Structure

```
wiseling-ms/
├── services/
│   ├── auth-service/          FastAPI - authentication & JWT
│   ├── wallet-service/        FastAPI - balances & ledger
│   ├── conversion-service/    FastAPI - FX conversions + outbox poller + cleaner
│   ├── withdrawal-service/    FastAPI - P2P transfers + outbox poller + cleaner + processor
│   └── frontend-service/      nginx SPA
├── shared/                    Shared JWT, SQS, DynamoDB clients
├── kubernetes-manifests/      Primary cluster Kubernetes YAMLs
│   ├── deployments/
│   │   ├── blue-deployments/
│   │   └── green-deployments/
│   ├── services/
│   ├── ingress.yaml
│   ├── configmap/
│   ├── secrets/
│   ├── karpenter/
│   ├── network-policies/
│   ├── pdbs/
│   └── irsa/
├── kubernetes-manifests-dr/   DR cluster Kubernetes YAMLs (mirrors primary)
├── terraform/
│   └── layers/                Primary region infrastructure
│       ├── 01-network/
│       ├── 02-data/
│       ├── 03-iam/
│       ├── 04-eks/
│       ├── deploy.sh
│       └── destroy.sh
│   └── layers-dr/             DR region infrastructure
│       ├── 01-network-sgp/
│       ├── 02-data-sgp/
│       ├── 03-iam-sgp/
│       ├── 04-eks-sgp/
│       └── 05-global/
└── scripts/
    ├── deploy/                 Cluster bootstrap scripts
    ├── smoke-tests/            End-to-end test runner
    ├── observability/          Grafana ingress & Prometheus stack install
    └── create-secret-update-secretsmanager/
```