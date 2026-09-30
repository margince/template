# Margince on AWS, light

One Ubuntu 24.04 EC2 instance in a customer's AWS account.
Terraform creates the infrastructure only. The template's `host` adapter
deploys Margince to the instance: Docker Compose, Caddy with an automatic HTTPS
certificate, and PostgreSQL 16 and Redis as containers on the instance
([docs/deploy.md, Section 5](../../../../docs/deploy.md#5-the-host-adapter)).
The Azure light stack ([../../azure/light](../../azure/light/README.md)) has the
same shape, variables and outputs.

## 1. What it creates

| Area | Resources |
|---|---|
| Compute | One EC2 instance, `t3.large` (2 vCPU, 8 GiB, x86_64), Canonical Ubuntu 24.04 LTS AMI from SSM. IMDSv2 required. User `ubuntu` with passwordless `sudo`, key pair from `admin_ssh_public_key`. |
| Storage | 30 GB encrypted gp3 root volume. 64 GB encrypted gp3 data volume (`prevent_destroy`), mounted at `/var/lib/docker` by cloud-init before Docker is installed. Every Docker volume (`pgdata`, `redisdata`, `blobs`, `caddydata`) is on it. |
| Network | VPC with one public subnet, Elastic IP. Security group: 80 and 443 from the internet, 22 from `ssh_allowed_cidrs` only. Outbound open. |
| Secrets | SSM Parameter Store SecureString `/<name_prefix>/margince-license` with the license. The instance does not read it. |
| Backup | Data Lifecycle Manager: daily snapshots of the data and the root volume, 7 kept (`enable_backup`). |
| Alarms | SNS topic and three CloudWatch alarms: system status check with auto-recover, instance status check failed for 5 minutes, CPU over 90% for 15 minutes (`enable_alarms`, `alert_email`). |

cloud-init does one thing: it formats the data volume when it has no
filesystem, mounts it by UUID with `nofail`, and makes `docker.service`
require the mount. It also bind-mounts `/var/lib/docker/margince-host` at
`/opt/margince`, owned by the SSH user, so the adapter's default `HOST_DIR`
(`/opt/margince/<name>`, with `shared/instance.env` and `shared/data.env`) is
on the data volume too. It does not install Docker or Margince. Keep `HOST_DIR`
unset, or under `/opt/margince`.

## 2. Cost

eu-central-1, on demand, about **USD 80 per month**:

| Item | USD per month |
|---|---|
| EC2 `t3.large` | about 63 (`t4g.large`: about 56) |
| gp3 volumes, 94 GB | about 9 |
| Elastic IP (public IPv4) | about 4 |
| Snapshots (`enable_backup`), incremental | about 2 to 5 |
| Alarms, SNS, SSM Standard | less than 1 |

## 3. Prerequisites

| Requirement | Detail |
|---|---|
| AWS permissions | EC2, EBS, VPC, IAM role creation (Data Lifecycle Manager), CloudWatch, SNS and SSM in the account. |
| Tools | Terraform 1.10.0 or later, AWS CLI, `ssh`, `ssh-keyscan`. |
| State | An S3 bucket for the remote state (`backend.hcl.example`). |
| Instance | The instance repository with `make install` done, and the registry settings of [docs/release.md](../../../../docs/release.md#5-repository-settings). |
| License | A production license, or a test environment ([docs/deploy.md, Section 5.8](../../../../docs/deploy.md#58-the-license-check)). |
| Architecture | The release images must exist for `cpu_architecture`. `release.yml` builds the repository variable `PLATFORMS`, default `linux/amd64`. For `arm64` (`t4g.large`), set `PLATFORMS` to `linux/amd64,linux/arm64` first. |

## 4. Deploy

Run the `terraform` commands in `deploy/production/aws/light` and the `make`
commands in the repository root.

### 4.1 Apply

1. Copy `backend.hcl.example` to `backend.hcl` and fill it in.
2. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in `domain`,
   `admin_ssh_public_key` and `ssh_allowed_cidrs`. Set `license_token` to
   store the license in SSM.
3. Apply:

   ```sh
   terraform init -backend-config=backend.hcl
   terraform apply
   ```

4. Wait until cloud-init has mounted the data volume:

   ```sh
   $(terraform output -raw ssh_command) cloud-init status --wait
   ```

   `status: done` is required. On `status: error`, read
   `/var/log/cloud-init-output.log` on the instance.

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
   from the instance's console output.
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

2. Set the values of `secret_names` from SSM. Run the commands that
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

## 5. Upgrades

An upgrade is a deployment of a new version:

```sh
make release VERSION=<v>
REGISTRY=<registry> make deploy ENV=production VERSION=<v>
```

Rollback and its limits: [docs/deploy.md, Section 5.12](../../../../docs/deploy.md#512-rollback-limits).

A change of `user_data` replaces the instance. The data volume and the
Elastic IP stay. After a replacement:

1. Wait for `cloud-init status --wait` (Section 4.1).
2. Get the new host key into `HOST_KNOWN_HOSTS` (Section 4.4).
3. Run `make host-bootstrap ENV=production`.
4. Run `make deploy ENV=production VERSION=<v>`. The volumes and
   `HOST_DIR` are on the data volume, so the data, the database passwords and
   the generated keys are kept.

## 6. Backups and restore

With `enable_backup = true`, Data Lifecycle Manager snapshots the data volume
and the root volume daily at 02:00 UTC, selected by the tag
`Backup = <name_prefix>-daily`, and keeps 7. The template itself does not
back up the database ([docs/deploy.md, Section 5.13](../../../../docs/deploy.md#513-backups)).

| Task | Action |
|---|---|
| Restore the data volume | Create a volume from a snapshot in the instance's zone, stop the instance, detach the data volume, attach the restored volume as `/dev/sdf`, start the instance. Then `terraform import` the restored volume into `aws_ebs_volume.data` (after `terraform state rm` of the old one). |
| Keep the instance keys | Also copy `$HOST_DIR/shared/instance.env` off the instance and store it securely. `MARGINCE_KEYVAULT_ROOT_KEY` opens the sealed data; a snapshot without it is not enough. |

A snapshot of a running database is crash-consistent. For an
application-consistent copy, also run `pg_dump` in the `postgres` container on
a schedule.

## 7. AWS notes

### 7.1 Architecture

`cpu_architecture` selects the AMI and must match `instance_type`: `x86_64`
with `t3.large` (default), `arm64` with `t4g.large`. The release images must
exist for that architecture (Section 3).

### 7.2 Recovery

The system status alarm runs EC2 auto-recover: the instance moves to healthy
hardware and keeps its ID, Elastic IP and volumes. The instance status alarm
only notifies; reboot the instance.

### 7.3 Access

| Task | Command |
|---|---|
| Shell on the instance | `terraform output -raw ssh_command` |
| Logs | `docker compose -p margince-<name> logs` on the instance, in `$HOST_DIR/current` |
| Console output | `aws ec2 get-console-output --instance-id <id> --latest --output text` |

## 8. Versions

| Component | Version | Source |
|---|---|---|
| Ubuntu | 24.04 LTS | `ec2.tf`, current AMI at create time; later AMIs are ignored |
| Docker Engine, Compose plugin | Docker's apt repository | `make host-bootstrap` |
| PostgreSQL | 16 with pgvector | the image the host adapter pins (`scripts/deploy/host/compose.yaml`) |
| Redis | 7.2 | the image the host adapter pins (`scripts/deploy/host/compose.yaml`) |
| Terraform | 1.10.0 or later | `versions.tf` |
| Providers | aws ~> 5.60 | `versions.tf` |

## 9. Tests

```sh
terraform init -backend=false
terraform validate
terraform test          # offline checks with mocked providers
```
