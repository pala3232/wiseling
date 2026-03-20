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
| `withdrawal-processor` | — | Publishes transfer events to SQS |
| `conversion-dynamo-cleaner` | — | Cleans DynamoDB buffer after RDS recovery |
| `withdrawal-dynamo-cleaner` | — | Cleans DynamoDB buffer after RDS recovery |
| `wallet-reconciler` | — | Replays DynamoDB buffer on startup after failover |
| `redis` | 6379 | In-memory cache (master + replica) used by wallet-service and wallet-consumer |
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

### FX Rates

By default, conversion-service uses static hardcoded rates (`RATES_PROVIDER: static` in the configmap). To switch to live rates, set `RATES_PROVIDER: openexchangerates` and add your API key from [openexchangerates.org](https://openexchangerates.org) as `OPEN_EXCHANGE_RATES_APP_ID` in Secrets Manager, then pull it via External Secrets into the pod.

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
- DR database is an RDS read replica — **reads work, writes fail** until the `09 | Failover to DR` workflow promotes it
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

**2. Build and push images** via **02 | Build Push Deploy** — run once per service with an initial tag (e.g. `1.0.0`).

**3. Deploy infrastructure** via **01 | Deploy Infrastructure** (leave `target` blank to run all stages).

**4. Deploy primary cluster** via **03 | Deploy Kubernetes Cluster** — select `primary`.

**5. Deploy DR cluster** via **03 | Deploy Kubernetes Cluster** — select `dr`.

**6. Deploy global layer:**
- Run **01 | Deploy Infrastructure** → target `global`, protocol `HTTP`
- Copy the Route53 nameservers from the workflow logs and set them as custom nameservers in Cloudflare for your domain
- Wait for cert validation (~5-15 min). Check with:
  ```bash
  aws acm describe-certificate --certificate-arn <arn> --region ap-southeast-2 --query 'Certificate.Status'
  ```
- Once `ISSUED`, re-run **01 | Deploy Infrastructure** → target `global`, protocol `HTTPS`
- Run **04 | Configure HTTPS** → paste the primary and DR cert ARNs from the workflow logs

**7. Deploy observability** via **05 | Deploy Observability**.

### Destroy Infrastructure

Trigger **10 | Destroy Infrastructure**. `00-bootstrap` (ECR + OIDC role) is intentionally excluded and survives destroy.

### Cost Report

Projects infrastructure costs from the manifest — no AWS credentials or running infrastructure needed for the estimate.

```bash
chmod +x scripts/cost/cost-report.sh
./scripts/cost/cost-report.sh
```

**Prerequisites:** `jq` (`winget install jqlang.jq` / `brew install jq` / `sudo apt install jq`)

Reads [`scripts/cost/infra-manifest.conf`](scripts/cost/infra-manifest.conf), prices each resource, and outputs estimated cost per hour, per 24h, and per 30 days. Update the manifest when infrastructure changes and re-run.

Supported resource types in the manifest: `eks_cluster`, `ec2`, `rds`, `nat_gateway`, `alb`, `route53_zone`, `route53_hc`, `secretsmanager_secret`, `cloudwatch_alarm`, `dynamodb_global_table`

EC2 and RDS prices are fetched live from the AWS Pricing API (`pricing:GetProducts` permission required). All other rates are hardcoded — see the rate functions in the script if your regions differ.

### Failover Test

Measures end-to-end failover time from primary failure to DR serving traffic, then restores primary.

```bash
chmod +x scripts/failover-test/failover-test.sh
./scripts/failover-test/failover-test.sh --domain <your-domain>
```

**Prerequisites:** `aws` CLI, `kubectl` (configured for primary cluster), `nslookup`, `curl`

What it does:
1. Scales down all primary deployments to 0 (triggers Route53 health check failure)
2. Polls until Route53 health check reports unhealthy
3. Polls until DNS resolves to a different IP (DR ALB)
4. Polls until DR endpoint returns HTTP 200 — reports total failover time
5. Prompts to restore — scales primary back to 2 replicas and reports recovery time

---

## CI/CD Workflows

| Workflow | Description |
|---|---|
| `01 \| Deploy Infrastructure` | Apply one or all Terraform layers |
| `02 \| Build Push Deploy` | Build, push to ECR, and deploy a service to both clusters |
| `03 \| Deploy Kubernetes Cluster` | Bootstrap K8s on primary or DR cluster |
| `04 \| Configure HTTPS` | Patch ALB ingress with ACM cert ARNs on both clusters |
| `05 \| Deploy Observability` | Install Prometheus + Grafana on primary |
| `06 \| Smoke Tests` | End-to-end tests against live ALB |
| `07 \| Load Tests` | Run Locust + chaos experiments |
| `08 \| Build Locust` | Build and push Locust image to ECR |
| `09 \| Failover to DR` | Promote DR replica + restart pods (type `FAILOVER` to confirm) |
| `10 \| Destroy Infrastructure` | Destroy all infrastructure except 00-bootstrap (type `DESTROY` to confirm) |

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
