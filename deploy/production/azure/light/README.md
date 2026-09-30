# Margince on Azure, light

One Ubuntu 24.04 VM in a customer's Azure subscription and Entra ID tenant.
Terraform creates the infrastructure only. The template's `host` adapter
deploys Margince to the VM: Docker Compose, nginx for routing and per-address rate limits on the
credential endpoints (`AUTH_RATE_LIMIT_PER_MINUTE` in `host.env`, default
30), Caddy with an automatic HTTPS
certificate, and PostgreSQL 16 and Redis as containers on the VM
([docs/deploy.md, Section 5](../../../../docs/deploy.md#5-the-host-adapter)).
The AWS light stack ([../../aws/light](../../aws/light/README.md)) has the
same shape, variables and outputs.

## 1. What it creates

| Area | Resources |
|---|---|
| Compute | One VM, `Standard_B2ms` (2 vCPU, 8 GiB), Canonical Ubuntu 24.04 LTS server Gen2. Trusted Launch, encryption at host, Azure-orchestrated OS patching. Admin user `azureadmin` with passwordless `sudo`, SSH key login only. |
| Storage | 30 GB OS disk. 64 GB data disk (`prevent_destroy`), mounted at `/var/lib/docker` by cloud-init before Docker is installed. Every Docker volume (`pgdata`, `redisdata`, `blobs`, `caddydata`) is on it. |
| Network | VNet with one subnet, static Standard public IP. NSG: 80 and 443 from the internet, 22 from `ssh_allowed_cidrs` only. Outbound open. |
| Secrets | Key Vault (RBAC, purge protection, firewall open to `ssh_allowed_cidrs` only) with the Entra client secret and the license. The VM does not read it. |
| Identity | Entra app registration: single tenant, assignment required, your security group, staff sign-in and Graph mail. |
| Backup | Recovery Services vault: daily backup of the VM with its data disk, 7 days. |
| Alerts | Action group and two metric alerts: VM unavailable for 5 minutes, CPU over 90% for 15 minutes, to `alert_email`. |

cloud-init does one thing: it formats the data disk when it has no
filesystem, mounts it by UUID with `nofail`, and makes `docker.service`
require the mount. It also bind-mounts `/var/lib/docker/margince-host` at
`/opt/margince`, owned by the SSH user, so the adapter's default `HOST_DIR`
(`/opt/margince/<name>`, with `shared/instance.env` and `shared/data.env`) is
on the data disk too. It does not install Docker or Margince. Keep `HOST_DIR`
unset, or under `/opt/margince`.

## 2. Cost

West Europe, pay-as-you-go, about **EUR 75 per month**:

| Item | EUR per month |
|---|---|
| VM `Standard_B2ms` | about 55 |
| OS and data disk (StandardSSD) | about 8 |
| Static public IP | about 3 |
| Azure Backup | about 8 |
| Key Vault, alerts | less than 1 |

## 3. Prerequisites

| Requirement | Detail |
|---|---|
| Azure role | Owner, or Contributor and User Access Administrator, on the subscription. |
| Entra role | Application Administrator or Cloud Application Administrator, for `entra.tf`. |
| Tools | Terraform 1.10.0 or later, Azure CLI, `ssh`, `ssh-keyscan`. |
| State | A storage account for the remote state (`backend.hcl.example`). |
| Instance | The instance repository with `make install` done, and the registry settings of [docs/release.md](../../../../docs/release.md#5-repository-settings). |
| License | A production license, or a test environment ([docs/deploy.md, Section 5.8](../../../../docs/deploy.md#58-the-license-check)). |

Set the subscription and register encryption at host once; the VM always
uses it:

```sh
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
az feature register --namespace Microsoft.Compute --name EncryptionAtHost
az feature show --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state
az provider register --namespace Microsoft.Compute
```

## 4. Deploy

Run the `terraform` commands in `deploy/production/azure/light` and the `make`
commands in the repository root.

### 4.1 Apply

1. Copy `backend.hcl.example` to `backend.hcl` and fill it in.
2. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in the
   required variables below. `ssh_allowed_cidrs` must include the address
   you run Terraform from: the Key Vault firewall admits only these
   addresses.

   | Variable | Default | Meaning |
   |---|---|---|
   | `domain` | required | Public host name, for example `crm.example.com`. |
   | `admin_ssh_public_key` | required | ed25519 or RSA public key of the SSH user `azureadmin`. |
   | `ssh_allowed_cidrs` | required | IPv4 ranges for SSH and the Key Vault firewall. `0.0.0.0/0` is refused. |
   | `entra_access_group_object_id` | required | The Entra security group allowed to use Margince. |
   | `name_prefix` | `margince` | Prefix of the resource names; the resource group is `<name_prefix>-light`. |
   | `region` | `westeurope` | Azure region. |
   | `vm_size` | `Standard_B2ms` | VM size. |
   | `data_disk_gb` | `64` | Size of the data disk. |
   | `alert_email` | `""` | Receiver of the alerts. Empty adds none. |
   | `license_token` | `""` | `MARGINCE_LICENSE`, stored in Key Vault. |

3. Apply:

   ```sh
   terraform init -backend-config=backend.hcl
   terraform apply
   ```

4. Wait until cloud-init has mounted the data disk:

   ```sh
   $(terraform output -raw ssh_command) cloud-init status --wait
   ```

   `status: done` is required. On `status: error`, read
   `/var/log/cloud-init-output.log` on the VM.

### 4.2 DNS

Create the A record that `terraform output dns_record` prints, at your DNS
provider. A CAA record, if present, must allow `letsencrypt.org`.

### 4.3 host.env, config and secrets

1. Replace the `HOST_SSH=` and `HOST_DOMAIN=` lines of
   `deploy/production/host.env` with the output of:

   ```sh
   terraform output -raw host_env
   ```

2. Set `bootstrap_admin.email` and the workspace in
   `deploy/production/config/margince.yaml`.
3. Add every name that `terraform output secret_names` prints to
   `deploy/production/secrets`, one per line.
4. Commit and push. `make deploy` refuses uncommitted changes.

### 4.4 Known hosts

1. Run the commands that `terraform output -raw ssh_known_hosts_hint`
   prints. They read the host key with `ssh-keyscan` and the fingerprints
   from the VM's boot log.
2. Compare the ED25519 fingerprints. Continue only when they match.
3. Export `HOST_KNOWN_HOSTS` as the last line of the hint shows.

### 4.5 Install Docker

```sh
make host-bootstrap ENV=production
```

### 4.6 Release and deploy

1. Cut a release and wait until `release.yml` has pushed the images:

   ```sh
   make release VERSION=<v>
   ```

2. Set the values of `secret_names` from Key Vault. Run the commands that
   this prints:

   ```sh
   terraform output -raw secret_exports
   ```

3. Deploy. `REGISTRY` must be the value the release used:

   ```sh
   REGISTRY=<registry> make deploy ENV=production VERSION=<v>
   ```

### 4.7 First sign-in

1. Print the generated first admin password:

   ```sh
   make host-admin-password ENV=production
   ```

2. Sign in at `https://<domain>` as `bootstrap_admin.email` and change the
   password.
3. Complete the Entra ID steps in Section 7.1.

## 5. Upgrades

An upgrade is a deployment of a new version:

```sh
make release VERSION=<v>
REGISTRY=<registry> make deploy ENV=production VERSION=<v>
```

Rollback and its limits: [docs/deploy.md, Section 5.12](../../../../docs/deploy.md#512-rollback-limits).

A change of the cloud-init document replaces the VM. The data disk and the
public IP stay. After a replacement:

1. Wait for `cloud-init status --wait` (Section 4.1).
2. Get the new host key into `HOST_KNOWN_HOSTS` (Section 4.4).
3. Run `make host-bootstrap ENV=production`.
4. Run `make deploy ENV=production VERSION=<v>`. The volumes and
   `HOST_DIR` are on the data disk, so the data, the database passwords and
   the generated keys are kept.

## 6. Backups and restore

Azure Backup takes a daily recovery point of the
VM with its OS and data disk at 02:00 UTC and keeps 7. The template itself
does not back up the database ([docs/deploy.md, Section 5.13](../../../../docs/deploy.md#513-backups)).

| Task | Action |
|---|---|
| Restore the whole VM | Azure portal: Recovery Services vault `<name_prefix>-rsv` > Backup items > the VM > Restore VM. |
| Restore the data disk only | Restore disks, then swap the data disk of the VM, or attach the restored disk and copy the volumes. |
| Keep the instance keys | Also copy `$HOST_DIR/shared/instance.env` off the VM and store it securely. `MARGINCE_KEYVAULT_ROOT_KEY` opens the sealed data; a backup without it is not enough. |

A disk-level backup of a running database is crash-consistent. For an
application-consistent copy, also run `pg_dump` in the `postgres` container on
a schedule.

## 7. Azure notes

### 7.1 Entra ID

1. Grant admin consent for the app (Enterprise applications > Margince >
   Permissions). This needs Privileged Role Administrator or Global
   Administrator, so the stack leaves it to you.
2. Add the app (`entra_client_id` output) to the Conditional Access policy
   that protects your other business applications.
3. Check that Assignment required is Yes and that only your group is
   assigned.

### 7.2 Entra secret rotation

The first `terraform apply` after 180 days creates a new
client secret and writes it to Key Vault. Then run Section 4.6, steps 2 and
3, with the running version.

### 7.3 Access

| Task | Command |
|---|---|
| Shell on the VM | `terraform output -raw ssh_command` |
| Logs | `docker compose -p margince-<name> logs` on the VM, in `$HOST_DIR/current` |
| Boot log | `az vm boot-diagnostics get-boot-log -g <resource-group> -n <vm>` |

## 8. Versions

| Component | Version | Source |
|---|---|---|
| Ubuntu | 24.04 LTS | `vm.tf`, latest image at create time |
| Docker Engine, Compose plugin | Docker's apt repository | `make host-bootstrap` |
| PostgreSQL | 16 with pgvector | the image the host adapter pins (`scripts/deploy/host/compose.yaml`) |
| Redis | 7.2 | the image the host adapter pins (`scripts/deploy/host/compose.yaml`) |
| Terraform | 1.10.0 or later | `versions.tf` |
| Providers | azurerm ~> 4.81, azuread ~> 2.53, random ~> 3.6, time ~> 0.12 | `versions.tf` |

## 9. Tests

```sh
terraform init -backend=false
terraform validate
terraform test          # offline checks with mocked providers
```
