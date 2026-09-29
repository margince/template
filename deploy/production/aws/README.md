# Margince on AWS: deployment infrastructure

Terraform that stands up a complete Margince installation in your own AWS
account, in two flavours.

| Flavour | Path | For | Shape | Rough cost |
|---|---|---|---|---|
| **Light** | [`light/`](light/README.md) | Proof of concept, small pilots | Three EC2 instances (nginx edge, api with valkey, worker) building Margince from source, RDS PostgreSQL single-AZ, CloudFront with ACM in front, S3 for attachments | lowest |
| **Standard** | [`standard/`](standard/README.md) | Mid-size production | Containers on ECS Fargate behind an ALB (path routing, WAF), RDS PostgreSQL Multi-AZ, ElastiCache, S3, ECR, one customer-managed KMS key, VPC endpoints | higher |

Architecture diagrams are in [`docs/diagrams/`](docs/diagrams/).

## Requirements

- An AWS account and credentials that can create the resources above.
- Terraform 1.7+, the AWS CLI; Docker with buildx for the standard flavour's
  images.
- A checkout of the Margince source repository at the commit to deploy
  (`MARGINCE_REPO`): the light flavour builds on the instances from an
  archive of it, the standard flavour builds container images from it.
- A Margince licence.

## Quick start

```bash
export MARGINCE_REPO=~/src/margince
cd deploy/production/aws/light      # or: deploy/production/aws/standard
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
```

Then follow the flavour's README: each lists the one-time steps Terraform
does not do (certificate validation, database roles, `margince.yaml`,
images).

**State**: both flavours require the S3 backend (`backend.hcl`, Terraform
1.10+ for S3 native locking). State holds every generated credential, so the
bucket must be restricted to deployment identities.

## Scope

Autoscaling beyond a fixed floor and ceiling, multi-region, and disaster
recovery runbooks are out of scope; they are decisions for whoever operates
the installation.
