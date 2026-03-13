# wiseling-ms Context

## Project Purpose
wiseling-ms is a secure, production-grade microservices platform running on AWS EKS. It is designed for financial or transactional workloads, with a focus on automation, security, and scalability.

## Key Technologies
- **AWS EKS**: Managed Kubernetes cluster for container orchestration.
- **Terraform**: Infrastructure as code for AWS resources.
- **Karpenter**: Autoscaling of EKS nodes.
- **Kubernetes**: Deployments, Services, ConfigMaps, Secrets, and NetworkPolicies.
- **Python**: Main language for microservices and shared libraries.
- **NGINX**: Used in frontend-service for web UI delivery.

## Security Model
- **NetworkPolicies**: Deny-all by default, with explicit allow rules for required service-to-service and worker-to-service communication.
- **Secrets Management**: Uses Kubernetes secrets and AWS Secrets Manager for sensitive data.
- **Least Privilege**: Only necessary pod-to-pod and egress-to-AWS communication is allowed.

## Deployment & Operations
- **Blue/Green Deployments**: Enables safe, zero-downtime releases.
- **CI/CD**: Automated via scripts and best practices (pipelines not shown in repo).
- **Observability**: Grafana for monitoring; logs and metrics assumed to be collected.

## Service Overview
- **auth-service**: Authentication, JWT issuance/validation.
- **conversion-service**: Handles conversions (currency, value, etc.).
- **wallet-service**: Wallet management and balance tracking.
- **withdrawal-service**: Withdrawal request and processing.
- **frontend-service**: Web UI.
- **workers**: Background jobs for async processing (e.g., wallet-consumer, withdrawal-processor).

## Shared Code
- **shared/**: Common code for authentication, DynamoDB, and SQS integrations.

## Directory Highlights
- `kubernetes-manifests/`: All Kubernetes YAMLs, including deployments, services, and network policies.
- `services/`: Source code and Dockerfiles for each microservice.
- `shared/`: Python shared libraries.
- `scripts/`: Shell scripts for deployment and testing.
- `terraform/`: Infrastructure modules for AWS resources.

## Labeling Conventions
- `app: <service-or-worker-name>`: Used for pod selection in policies.
- `deployment: green`: Used for blue/green deployment targeting.

## Communication Policy
- Only explicitly allowed pod-to-pod communication is permitted.
- Egress to AWS endpoints is allowed for all pods.
- Worker pods are explicitly allowed to access services as needed.

---
This context file is intended to provide future prompts with a concise summary of the system's architecture, security model, and operational practices.
