# Margince on Azure: deployment infrastructure

Terraform that stands up a complete Margince installation in your own Azure
subscription and Entra ID tenant, in two flavours. Both sign staff in through
your Entra ID tenant (single-tenant app, assignment required, your security
group, your Conditional Access policy).

| Flavour | Path | For | Shape | Rough cost |
|---|---|---|---|---|
| **Light** | [`light/`](light/README.md) | Proof of concept, small pilots | One Ubuntu VM (Trusted Launch, platform patching) running nginx, api, worker and Redis 7.2 natively (built from source at first boot), Postgres Flexible 16 (B1ms), Key Vault, Let's Encrypt TLS | ~EUR 80 / month |
| **Standard** | [`standard/`](standard/README.md) | Mid-size production (about 40 users) | Containers on Azure Container Apps: api (3-6 replicas, HTTP and CPU scaling) with an nginx edge container as the only public entry, worker, Redis 7.2 container; Postgres Flexible 16, Azure Files, Key Vault with a customer-managed key, private endpoints, NAT egress IP, VNet flow logs, delete locks, alerts, backups and audit logs | ~EUR 410-545 / month |

Architecture, flows and cost details: [`docs/architecture.md`](docs/architecture.md).

## Versions

Both flavours run the versions Margince requires: **PostgreSQL 16** with
pgvector and **Redis 7.2**, the version Margince develops against (it
requires 7.0-7.2). Standard runs the `redis:7.2` image as a container, because
Azure Cache for Redis offers only Redis 6 on its Standard tier; light installs
Redis 7.2 from Redis's signed apt repository, pinned to the 7.2 series. Terraform uses the **AzureRM 4.x** provider; set
`ARM_SUBSCRIPTION_ID` (`az account show --query id -o tsv`) before running it.

## Requirements

- An Azure subscription where you are Owner (or Contributor plus User Access
  Administrator), and Entra ID Application Administrator for the app
  registration (or create it by hand; see each README).
- Terraform 1.7+, Azure CLI. Standard also needs `jq` and Docker with buildx
  to build images locally (or use its jumpbox build).
- A Margince licence. Standard builds images from a Margince source checkout
  (`MARGINCE_REPO`); light clones the public repository on the VM at the ref
  you choose (`margince_git_ref`).
- Remote Terraform state (`backend.hcl.example` in each flavour): state holds
  every generated password and the Entra client secret.

## Quick start

```bash
cd light                                      # or: cd standard
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform apply
```

Then follow the flavour's README for the remaining one-time steps (Entra
admin consent and Conditional Access, DNS and TLS, first login; for standard
also the database bootstrap, image build and `margince.yaml` upload before
`terraform apply -var deploy_apps=true`).

## Checks

```bash
cd light    # or standard
terraform init -backend=false
terraform validate
terraform test     # offline plan checks with mocked providers
```

Filled-in `*.tfvars` and `backend.hcl` files and local state are git-ignored.
