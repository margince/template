# Production environment

This directory holds the template's default `production` environment and the
Terraform that creates the cloud infrastructure for it.

## 1. Contents

| Path | Function |
|---|---|
| `host.env`, `secrets`, `config/` | The `host` adapter's configuration for `make deploy ENV=production` ([docs/deploy.md](../../docs/deploy.md)). |
| [`azure/`](azure/README.md) | Terraform for Azure: `light` (one VM) and `standard` (Azure Container Apps). |
| [`aws/`](aws/README.md) | Terraform for AWS: `light` (EC2) and `standard` (ECS Fargate). |

## 2. Terraform flavours

| Cloud | Light: proof of concept, small pilots | Standard: mid-size production |
|---|---|---|
| Azure | One Ubuntu VM, Postgres Flexible 16, Key Vault, Let's Encrypt TLS | Azure Container Apps, Postgres Flexible 16, Redis 7.2 container, private endpoints, customer-managed key |
| AWS | Three EC2 instances, RDS PostgreSQL single-AZ, CloudFront with ACM, S3 | ECS Fargate behind an ALB with WAF, RDS PostgreSQL Multi-AZ, ElastiCache, ECR, KMS, VPC endpoints |

Each flavour is a self-contained Terraform root module. Its README lists the
requirements and the one-time steps that Terraform does not do.

```bash
cd deploy/production/azure/light      # or azure/standard, aws/light, aws/standard
cp backend.hcl.example backend.hcl    # remote state: it holds every generated secret
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform apply
```

## 3. Scope

`make new-instance` replaces `deploy/` with a new `deploy/production/` from
`make deploy-init`, and `make template-sync` does not add `deploy/` files to an
instance. The Terraform in this directory is therefore in the template only.
Copy a flavour into an instance by hand to use it there.

## 4. Checks

```bash
cd deploy/production/azure/light      # or any other flavour
terraform init -backend=false
terraform validate
terraform test                         # offline plan checks, mocked providers
```

Filled-in `*.tfvars` and `backend.hcl` files, provider lock files, and local
state are git-ignored.
