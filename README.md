# Wiseling

Production-grade multi-currency wallet API with FX conversions and P2P transfers, built on AWS EKS using a microservices architecture with event-driven processing.

**Primary region:** ap-southeast-2 (Sydney) · **DR region:** ap-southeast-1 (Singapore)

---

## Architecture

![Wiseling Architecture](images/wiseling-infra-v2.drawio.png)

### Services

| Service | Port | Responsibility |
|---|---|---|
| `auth-service` | 8000 | Register, login, JWT, account number lookup |
| `wallet-service` | 8001 | Balances, ledger, recipient lookup |
| `conversion-service` | 8002 | FX conversions, rates |
| `withdrawal-service` | 8003 | P2P transfers |
| `wallet-consumer` | — | SQS consumer, debits/credits/transfers |
| `conversion-outbox-poller` | — | Publishes conversion events to SQS |
| `withdrawal-outbox-poller` | — | Publishes transfer events to SQS |
| `conversion-dynamo-cleaner` | — | Cleans DynamoDB buffer after RDS recovery |
| `withdrawal-dynamo-cleaner` | — | Cleans DynamoDB buffer after RDS recovery |
| `wallet-reconciler` | — | Replays DynamoDB buffer on startup after failover |
| `frontend` | 80 | Single-page app (nginx) |

### Event Flow — P2P Transfer

```
POST /api/v1/withdrawals/transfer
        │
        ▼
withdrawal-service
  ├── Resolves recipient via auth-service lookup
  ├── Writes Withdrawal record + OutboxEvent (atomic)
  ├── Writes to DynamoDB buffer (DR)
        │
        ▼
withdrawal-outbox-poller → SQS (wiseling-withdrawals)
        │
        ▼
wallet-consumer
  ├── Debits sender wallet
  ├── Credits recipient wallet
  └── PATCH /internal/{id}/complete → withdrawal-service
```

### Event Flow — FX Conversion

```
POST /api/v1/conversions
        │
        ▼
conversion-service
  ├── Writes Conversion record + OutboxEvent (atomic)
  ├── Writes to DynamoDB buffer (DR)
        │
        ▼
conversion-outbox-poller → SQS (wiseling-conversions)
        │
        ▼
wallet-consumer
  ├── Debits from_currency wallet
  └── Credits to_currency wallet
```

---

## Infrastructure

### Terraform Layers

```
terraform/
├── envs/
│   ├── primary/
│   │   ├── 00-bootstrap/   ECR repositories + GitHub Actions OIDC role (never destroyed)
│   │   ├── 01-network/     VPC, subnets, route tables, security groups, NAT gateway
│   │   ├── 02-data/        RDS, SQS (+DLQs), DynamoDB global table, JWT secret
│   │   ├── 03-eks/         EKS cluster, bootstrap node group, OIDC provider
│   │   └── 04-iam/         IRSA pod role, Karpenter role, all IAM policies
│   ├── dr/
│   │   ├── 01-network/     VPC, subnets (ap-southeast-1)
│   │   ├── 02-data/        RDS read replica, SQS queues
│   │   ├── 03-eks/         EKS cluster (Singapore)
│   │   └── 04-iam/         IRSA roles for DR cluster
│   └── global/             Route53 hosted zone, ACM certs, health checks, failover DNS
└── modules/
    ├── network/
    ├── data-primary/
    ├── data-dr/
    ├── eks/
    └── iam/
```

**Deploy order (primary):** `01-network → 02-data + 03-eks (parallel) → 04-iam`

**Deploy order (DR):** `01-network → 03-eks (parallel with primary stage 2) → 02-data + 04-iam`

**Global layer** runs separately after both clusters are up and ingresses have ALB DNS names.

`00-bootstrap` is applied once manually and never targeted by the pipeline or destroy workflow.

### AWS Resources

| Resource | Name |
|---|---|
| EKS Cluster (primary) | `wiseling-eks-cluster` |
| EKS Cluster (DR) | `wiseling-eks-cluster-sgp` |
| RDS PostgreSQL 16 (primary) | `wiseling-rds-instance` |
| RDS Read Replica (DR) | `wiseling-rds-replica-sgp` |
| SQS Queues | `wiseling-conversions`, `wiseling-withdrawals` |
| DynamoDB Table | `wiseling-outbox` (global, replicated to ap-southeast-1) |
| S3 State Backend | `wiseling-terraform-state-pala3105` |
| ECR | `359707702022.dkr.ecr.ap-southeast-2.amazonaws.com/wiseling/*` |

### Kubernetes

- **Namespace:** `wiseling`
- **Node provisioning:** Karpenter (dynamic) + 1 bootstrap `t3.large`
- **Autoscaling:** HPA on CPU (metrics-server) + Karpenter node autoscaling
- **Secrets:** AWS Secrets Manager via External Secrets Operator
- **Ingress:** AWS ALB Controller (internet-facing)
- **Network policies:** Default deny-all ingress, per-service allow rules

### Disaster Recovery

- Route53 **active-passive failover** — health checks on both ALBs, traffic auto-switches to DR when primary fails
- DR cluster runs at minimum capacity (1 replica per service, `t3.large` nodes) — scales up on failover
- DR database is an RDS read replica — **reads work, writes fail** until the `Failover to Singapore` workflow promotes it
- DynamoDB Global Table replicates outbox events to ap-southeast-1 in real time
- CloudWatch alarm + SNS email fires when primary health check fails

---

## Getting Started

### Prerequisites

- AWS CLI configured
- `terraform >= 1.3.0`
- `kubectl`, `helm`

### Required GitHub Secrets

| Secret | Description |
|---|---|
| `AWS_ROLE_ARN` | ARN of the GitHub Actions IAM role (from 00-bootstrap output) |
| `ADMIN_IAM_ARN` | Your IAM user/role ARN for kubectl admin access |
| `DB_PASSWORD` | RDS master password (8+ chars) |
| `DOMAIN_NAME` | Your registered domain (e.g. `wiseling.xyz`) |
| `ALERT_EMAIL` | Email to notify on primary region failure |

### First-Time Setup

**1. Bootstrap ECR and OIDC (run once locally):**
```bash
cd terraform/envs/primary/00-bootstrap
terraform init
terraform apply -var="github_repo=your-github-user/wiseling"
```
Copy the `github_actions_role_arn` output into the `AWS_ROLE_ARN` GitHub secret.

**2. Deploy infrastructure** via the **Deploy Terraform Infrastructure** workflow (leave `target` blank to run all stages).

**3. Deploy primary cluster** via the **Deploy Kubernetes Cluster** workflow — select `primary`.

**4. Deploy DR cluster** via the **Deploy Kubernetes Cluster** workflow — select `dr`.

**5. Deploy global layer:**
- First run: **Deploy Terraform Infrastructure** → target `global`, protocol `HTTP`
- Copy the Route53 nameservers from the output and set them as custom nameservers in your DNS provider
- Wait for cert validation, then re-run with protocol `HTTPS`

**6. Deploy observability** via the **Deploy Observability Stack** workflow.

### Destroy Infrastructure

Trigger the **Destroy All Infrastructure** workflow. `00-bootstrap` (ECR + OIDC role) is intentionally excluded and survives destroy.

---

## CI/CD Workflows

| Workflow | Trigger | Description |
|---|---|---|
| `build-push-deploy.yml` | Manual | Build, push to ECR, and deploy to both clusters |
| `deploy-cluster.yml` | Manual | Bootstrap K8s on primary or DR cluster |
| `deploy-infra.yml` | Manual | Apply one or all Terraform layers |
| `destroy-all.yml` | Manual (type `DESTROY`) | Destroy all infrastructure except 00-bootstrap |
| `deploy-observability.yml` | Manual | Install Prometheus + Grafana on primary |
| `failover.yml` | Manual (type `FAILOVER`) | Promote DR replica + restart pods |
| `smoke-tests.yml` | Manual | End-to-end tests against live ALB |

---

## API Reference

All endpoints except `/api/v1/auth/register`, `/api/v1/auth/login`, and `/api/v1/conversions/rates` require `Authorization: Bearer <token>`.

### Auth — `POST /api/v1/auth/register`
```json
{ "email": "user@example.com", "password": "yourpassword" }
```
Returns `{ "id", "email", "account_number" }`. Creates 3 starter wallets (USD, EUR, GBP).

### Auth — `POST /api/v1/auth/login`
Form-encoded: `username=user@example.com&password=yourpassword`
Returns `{ "access_token", "token_type" }`.

### Auth — `GET /api/v1/auth/me`
Returns current user including `account_number`.

### Wallet — `GET /api/v1/wallet/balances`
Returns array of `{ "id", "currency", "balance" }`.

### Wallet — `GET /api/v1/wallet/lookup/{account_number}`
Resolves an account number to `{ "user_id", "email", "account_number" }`.

### Conversions — `POST /api/v1/conversions`
```json
{ "from_currency": "USD", "to_currency": "EUR", "amount": "100", "idempotency_key": "<uuid>" }
```
Fee: 0.30%. Status is `PENDING` immediately; wallet balances update asynchronously via SQS.

### Conversions — `GET /api/v1/conversions/rates`
Returns live FX rates, e.g. `{ "EUR/USD": "1.0889", "GBP/USD": "1.2763" }`.

### Transfers — `POST /api/v1/withdrawals/transfer`
```json
{ "to_account_number": "1234-5678-9012", "currency": "USD", "amount": "50", "idempotency_key": "<uuid>" }
```
Fee-free. Status updates to `COMPLETED` after wallet-consumer processes the SQS event.

### Transfers — `GET /api/v1/withdrawals`
Lists transfers sent by the current user.

### Transfers — `GET /api/v1/withdrawals/received`
Lists transfers received by the current user.

---

## Local Development

Each service is a standalone FastAPI app:

```bash
cd services/auth-service
pip install -e .
uvicorn app.main:app --reload --port 8000
```

Services expect `DATABASE_URL` and other config via environment variables. See each service's `app/core/config.py` for all settings.

---

## Project Structure

```
wiseling-ms/
├── services/
│   ├── auth-service/
│   ├── wallet-service/
│   ├── conversion-service/
│   ├── withdrawal-service/
│   └── frontend-service/
├── shared/                       # Shared JWT, SQS, DynamoDB clients
├── kubernetes-manifests/         # Primary cluster manifests
│   ├── deployments/
│   ├── services/
│   ├── ingress.yaml
│   ├── configmap/
│   ├── secrets/
│   ├── karpenter/
│   ├── pdbs/
│   └── network-policies/
├── kubernetes-manifests-dr/      # DR cluster manifests
├── terraform/
│   ├── envs/
│   │   ├── primary/
│   │   ├── dr/
│   │   └── global/
│   └── modules/
└── scripts/
    ├── deploy/
    ├── smoke-tests/
    └── observability/
```
