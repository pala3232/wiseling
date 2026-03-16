# Wiseling

Production-grade multi-currency wallet API with FX conversions and P2P transfers, built on AWS EKS using a microservices architecture with event-driven processing.

**Live region:** ap-southeast-2 (Sydney) · **DR region:** ap-southeast-1 (Singapore) * DR Region to be finished soon. Infra graph doesn't include it.

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
terraform/layers/
├── 01-network/   VPC, subnets, route tables, security groups, NAT gateway
├── 02-data/      RDS, SQS (+ DLQs), DynamoDB global table, ECR, JWT secret
├── 03-iam/       IRSA pod role, Karpenter role, all IAM policies
├── 04-eks/       EKS cluster, bootstrap node group, OIDC provider
├── deploy.sh     Apply all layers in order
└── destroy.sh    Destroy all layers in reverse (drains Karpenter nodes first)
```

**Apply order:** `01-network → 02-data → 04-eks → 03-iam`

IAM (03) reads the OIDC provider ARN from EKS (04) state, so EKS must exist first.

**Destroy order:** `03-iam → 04-eks → 02-data → 01-network`

ECR repos have `prevent_destroy = true` and survive full destroy.

### AWS Resources

| Resource | Name |
|---|---|
| EKS Cluster | `wiseling-eks-cluster` |
| RDS PostgreSQL 16 | `wiseling-rds-instance` |
| SQS Queues | `wiseling-conversions`, `wiseling-withdrawals` |
| DynamoDB Table | `wiseling-outbox` (global, replicated to ap-southeast-1) |
| S3 State Backend | `wiseling-terraform-state-pala3105` |
| ECR | `359707702022.dkr.ecr.ap-southeast-2.amazonaws.com/wiseling/*` |

### Kubernetes

- **Namespace:** `wiseling`
- **Node provisioning:** Karpenter (dynamic) + 1 bootstrap `t3.medium`
- **Secrets:** AWS Secrets Manager via External Secrets Operator
- **Ingress:** AWS ALB Controller (internet-facing)
- **Network policies:** Default deny-all ingress, per-service allow rules

### Database

Single RDS instance with 4 schemas, one per service. All services use `create_all` on startup (no Alembic). One IAM role (`pod-role`) for all app pods via IRSA.

### Disaster Recovery

DynamoDB Global Table (`wiseling-outbox`) replicates outbox events to ap-southeast-1 in real time. On regional failover, `wallet-reconciler` replays unprocessed events from the DynamoDB buffer to restore consistency.
DR cluster to be commited soon.
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
Fee-free. Instant. Status updates to `COMPLETED` after wallet-consumer processes the SQS event.

### Transfers — `GET /api/v1/withdrawals`
Lists transfers sent by the current user.

### Transfers — `GET /api/v1/withdrawals/received`
Lists transfers received by the current user.

---

## Getting Started

### Prerequisites

- AWS CLI configured with sufficient permissions
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
| `DB_PASSWORD` | RDS master password (8+ chars, no special chars) |

### Deploy Infrastructure

```bash
export TF_VAR_admin_iam_arn="arn:aws:iam::123456789:user/your-user"
export TF_VAR_db_password="YourPassword123"
cd terraform/layers
./deploy.sh
```

Or trigger the **Deploy Terraform Infrastructure** GitHub Actions workflow.

### Bootstrap the Cluster

After infrastructure is up, run the **Deploy Observability Stack** workflow, then run:

```bash
./scripts/deploy/deploy.sh
```

This installs the AWS Load Balancer Controller, Karpenter, External Secrets Operator, and applies all Kubernetes manifests.

### Populate the JWT Secret

```bash
aws secretsmanager put-secret-value \
  --secret-id wiseling-jwt-secret-key \
  --secret-string "$(openssl rand -hex 32)" \
  --region ap-southeast-2
```

### Destroy Infrastructure

```bash
cd terraform/layers
./destroy.sh
```

The destroy script drains all Karpenter-managed nodes before destroying the cluster, preventing orphaned EC2 instances.

To destroy only the EKS cluster (without touching network or data):
```bash
./destroy.sh 04-eks
```

---

## CI/CD Pipelines

| Workflow | Trigger | Description |
|---|---|---|
| `build-push-*.yml` | Push to `main` | Build and push service images to ECR |
| `deploy-infra.yml` | Manual | Apply one or all Terraform layers |
| `destroy-infra.yml` | Manual (requires `DESTROY`) | Destroy one or all Terraform layers |
| `deploy-observability.yml` | Manual | Install Prometheus + Grafana stack |
| `smoke-tests.yml` | Manual | Run end-to-end smoke tests against live ALB |

### Running Smoke Tests

Trigger the **Smoke Tests** workflow. It auto-resolves the ALB URL from the cluster. Tests cover:

- User registration and login
- Wallet initialisation (3 wallets on register)
- FX conversion creation and idempotency
- Recipient lookup by account number
- P2P transfer creation, idempotency, self-transfer rejection
- Balance verification after transfer
- Security — invalid and missing tokens

---

## Local Development

Each service is a standalone FastAPI app. To run locally:

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
├── shared/                     # Shared JWT, SQS, DynamoDB clients
├── kubernetes-manifests/
│   ├── deployments/
│   ├── services/
│   ├── ingress.yaml
│   ├── configmap/
│   ├── secrets/
│   ├── karpenter/
│   └── network-policies/
├── terraform/
│   └── layers/
│       ├── 01-network/
│       ├── 02-data/
│       ├── 03-iam/
│       ├── 04-eks/
│       ├── deploy.sh
│       └── destroy.sh
└── scripts/
    ├── deploy/
    ├── smoke-tests/
    └── observability/
```