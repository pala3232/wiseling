## Wiseling Microservices Platform

Private repo. Initially DB was going to be a self-hosted postgres until DR questions hit up. So I'll make it complex this time.

Contains the "Wiseling" microservices backend, designed for secure and scalable financial operations. It includes:

- **Auth Service**: Handles authentication and JWT management
- **Wallet Service**: Manages user wallets and balances
- **Conversion Service**: Currency conversion and rates
- **Withdrawal Service**: Handles withdrawals and payment processing

### Infrastructure
- **Terraform**: Infrastructure as code for AWS (EKS, RDS, DynamoDB, SQS, IAM, Route 53)
- **Kubernetes**: Manifests for deployment, config, and secrets management
- **AWS Secrets Manager**: Secure secret storage, integrated via External Secrets Operator
- **DynamoDB Global Table**: High-availability, cross-region outbox buffer

### Deployment
- CI/CD with GitHub Actions: Build, test, push to ECR, deploy to EKS. Deploy Infra.
- Blue/green deployment and failover runbook will be included

### Runbook & Operations
- Automated failover, reconciliation, and monitoring
- Runbook will be published ASAP

### Left to build soon:
- finishing netpolicies
- CloudFront distribution for ALB