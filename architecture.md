# wiseling-ms Architecture

## Overview
wiseling-ms is a microservices-based platform deployed on AWS EKS, using Kubernetes for orchestration and Terraform for infrastructure as code. The system is designed for production-grade reliability, security, and scalability, with blue/green deployments, Karpenter autoscaling, and robust CI/CD.

## Core Components
- **Infrastructure**: Managed by Terraform, provisioning EKS, RDS, DynamoDB, SQS, and supporting AWS resources.
- **Kubernetes**: Manages deployments, services, configmaps, secrets, and network policies for all microservices.
- **Karpenter**: Provides dynamic autoscaling for EKS nodes.
- **CI/CD**: Automated deployment pipelines (not shown in repo, assumed via scripts and best practices).

## Microservices
- **auth-service**: Handles authentication and JWT management.
- **conversion-service**: Manages currency or value conversions.
- **wallet-service**: Handles wallet operations and balances.
- **withdrawal-service**: Manages withdrawal requests and processing.
- **frontend-service**: Serves the web UI via NGINX.
- **workers**: Background jobs (wallet-consumer, withdrawal-processor, conversion-dynamo-cleaner, etc.) for async processing.

## Shared Libraries
- **shared/**: Contains common code for auth, DynamoDB, and SQS integrations.

## Security
- **NetworkPolicies**: Strictly control pod-to-pod communication, allowing only necessary ingress/egress based on service dependencies and worker requirements.
- **Secrets**: Managed via Kubernetes secrets and AWS Secrets Manager.

## Deployment Patterns
- **Blue/Green Deployments**: Separate deployment folders for green deployments, enabling zero-downtime releases.
- **Karpenter**: Ensures efficient, cost-effective autoscaling.

## Observability
- **Grafana**: Deployed for monitoring and observability.

## Directory Structure (Key Folders)
- `kubernetes-manifests/`: All Kubernetes YAMLs (deployments, services, network policies, etc.)
- `services/`: Source code and Dockerfiles for each microservice.
- `shared/`: Shared Python code for all services.
- `scripts/`: Shell scripts for deployment, secrets management, and smoke tests.
- `terraform/`: All Terraform modules for AWS infrastructure.

## Key Labels
- `app: <service-or-worker-name>`: Used for pod selection in NetworkPolicies.
- `deployment: green`: Used for blue/green deployment selection.

## Communication Patterns
- Only explicitly allowed service-to-service and worker-to-service communication is permitted by NetworkPolicies.
- Egress to AWS endpoints is allowed for all pods as needed.

---
