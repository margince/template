# Margince on Azure, light (proof of concept)

The cheapest way to run Margince in a customer's Azure subscription and Entra
ID tenant: one VM that builds Margince from source and runs it natively,
plus a small managed Postgres. For production use the standard stack.

## What it creates

| Area | Resources |
|---|---|
| Compute | One Ubuntu 24.04 VM (`Standard_B2ms`), system-assigned identity, static public IP with an Azure DNS name. nginx (TLS, SPA, reverse proxy), `margince-api`, `margince-worker` and Redis 7.2 (Redis's signed apt repository, pinned to 7.2, the same version as the standard stack) under systemd. Trusted Launch, encryption at host, Azure-orchestrated OS patching. |
| Storage | 64 GB data disk at `/var/lib/margince`: attachments (`MARGINCE_BLOBSTORE_PATH`), Redis data, `margince.yaml`, certificates, build cache. |
| Database | Postgres Flexible Server 16, `B_Standard_B1ms`, 32 GB (auto-grow), VNet-only, TLS 1.2+ required, failed-login throttling, 7-day backups. |
| Secrets | Key Vault (standard, RBAC, firewall open only to the VM and `operator_ip_allowlist`) with every generated secret; the VM identity reads them at service start. |
| Network | VNet with a VM subnet and a delegated Postgres subnet. NSG: 80/443 from the Internet, SSH only from Azure Bastion Developer (free). |
| Identity | Entra app registration (single tenant, assignment required, your security group) for staff sign-in and Graph mail. |

```
Internet ─443─> nginx ──127.0.0.1:8080──> margince-api ─┬─> Postgres (VNet, TLS)
                 │ SPA, 403 on password login           ├─> Redis 127.0.0.1:6379 
                 │ outside break_glass_cidrs            └─> Graph, Dataverse, LLM (from the public IP)
                 └ rate limits on auth paths    margince-worker ─┘
```

## What it is not

- **One VM, no high availability.** A VM or zone failure is an outage until
  the VM is back. Postgres has point-in-time restore; the VM and its data
  disk are backed up only with `enable_vm_backup = true` (daily, 7 days).
- **Builds on the box.** First boot clones the repository and compiles the
  Go binaries and the SPA (about 15 minutes on B2ms). Nothing is signed or
  pinned beyond the git ref you choose.
- **No WAF, no log shipping, no alerts.** Logs are in journald and
  `/var/log/nginx` on the VM.

Cost, West Europe, pay-as-you-go: about **EUR 80/month** (VM ~55, Postgres
~17, disks ~8, public IP ~3; Bastion Developer and Key Vault are free or
cents). `enable_vm_backup` adds about EUR 8. Stop the VM and Postgres to pay
mostly for storage.

## Steps

**1. Backend and variables.** You need Owner (or Contributor plus User Access
Administrator) on the subscription and Entra Application Administrator.
azurerm 4.x needs the subscription explicitly, and encryption at host needs a
one-time feature registration (skip it with `encryption_at_host = false`):

```bash
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
az feature register --namespace Microsoft.Compute --name EncryptionAtHost
az feature show --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state  # wait for "Registered"
az provider register --namespace Microsoft.Compute
```

```bash
cd light
cp backend.hcl.example backend.hcl            # fill in
cp terraform.tfvars.example terraform.tfvars  # fill in
terraform init -backend-config=backend.hcl
```

`operator_ip_allowlist` must hold the public IP you run Terraform from: the
Key Vault firewall denies every other address, and Terraform writes the
secrets through it. The admin SSH key may be RSA or ed25519; RSA is the safe choice for the
Bastion portal login.

**2. Apply.**

```bash
terraform apply
```

The VM then provisions itself. Follow it from Bastion (`ssh_via_bastion`
output) with `sudo tail -f /var/log/margince-setup.log`. If a step fails, fix
the cause and run `sudo margince-setup` again.

**3. DNS.** Without `public_hostname`, Margince is served at
`https://<label>.<region>.cloudapp.azure.com` (`azure_fqdn` output) and gets
its certificate at first boot; skip to step 5. With your own hostname,
create an A record to the `public_ip` output (or a CNAME to `azure_fqdn`).
A CAA record, if present, must allow `letsencrypt.org`.

**4. Enable TLS** (custom hostname only), once DNS resolves:

```bash
sudo margince-enable-tls
```

It checks that the name points at the VM, gets a Let's Encrypt certificate
and reloads nginx. The certbot timer renews it.

**5. Entra ID** (Entra admin, once): grant admin consent for the app
(Enterprise applications → Margince → Permissions), unless
`entra_grant_admin_consent = true`; add the app (`entra_client_id` output) to
the Conditional Access policy that protects Dataverse; check that
Assignment required = Yes and only your group is assigned.

**6. First login.** From a `break_glass_cidrs` address, sign in as
`bootstrap_admin_email` with the password from the `admin_password_command`
output, set the permanent password and keep it as the break-glass account.
Turn on Microsoft sign-in in Margince's settings and test it.

**7. Close.** Remove the `bootstrap_admin` section from
`/app/config/margince.yaml` and restart `margince-api`. Once the organization
exists the api ignores the bootstrap password and deletes its file;
`include_bootstrap_admin = false` also stops passing it, but replaces the VM
(see below), so fold it into your next planned change.

## Operating it

| Task | Command on the VM |
|---|---|
| Upgrade Margince | `sudo margince-build <branch, tag or commit>` (restarts the services; the api migrates) |
| Roll back | `sudo ln -sfn /opt/margince/releases/<old> /opt/margince/current && sudo systemctl restart margince-api margince-worker` |
| Logs | `journalctl -u margince-api -u margince-worker -f` |
| Entra secret rotation | after the apply that rotates it: `sudo systemctl restart margince-api margince-worker` |
| Re-run the database bootstrap | `sudo margince-bootstrap-db` (idempotent) |

Changing a variable that feeds cloud-init (nginx rules, workspace settings,
git ref, posture) **replaces the VM**. The data disk, public IP, Key Vault and
Postgres stay; the new VM rebuilds in about 20 minutes and keeps
`margince.yaml`, attachments and certificates. Plain upgrades should use
`margince-build` instead.

Dataverse: add the `egress_ip` output to the Dataverse IP firewall.

## Security notes

- Public surface: nginx on 80 (ACME and redirect) and 443. cmd/api listens on
  loopback only; Redis, the worker's health port and `/metrics` are not
  reachable from outside.
- Password login is refused outside `break_glass_cidrs`; everyone else signs
  in with Entra ID under your Conditional Access policy.
- Secrets live in Key Vault and in `/etc/margince/secrets.env` (root and the
  service user only). api and worker share that file on this single VM.
- Postgres has no public endpoint; connections use TLS with full
  certificate verification.
- nginx uses Mozilla's "intermediate" TLS profile (TLS 1.2/1.3) with HSTS.
- Key Vault accepts only the VM's public IP and `operator_ip_allowlist`;
  `admin_password_command` works only from those addresses.

## Tests

```bash
terraform init -backend=false
terraform validate
terraform test          # offline checks with mocked providers
```
