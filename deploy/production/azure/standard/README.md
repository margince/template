# Margince on Azure

Terraform root module that deploys Margince into your own Azure subscription
and Entra ID tenant, sized for a small team (about 40 users). The application
images are built from the Margince source repository; this stack deploys them.

## What it creates

| Area | Resources |
|---|---|
| Compute | Container Apps environment (workload profiles, Consumption profile, zone-redundant). **api** app (3 to 6 replicas, CPU and HTTP scale rules): `cmd/api` plus an **edge** nginx container that serves the SPA and is the only public entry. **worker** app: no ingress. **redis** app: Redis 7.2, one replica, internal TCP only. |
| Data | Postgres Flexible Server 16 (VNet-integrated, customer-managed key, auto-grow, Entra and password auth; single-zone Burstable B2s by default, zone-redundant HA with `db_sku_name` General Purpose and `db_zone_redundant_ha = true`), Storage account with `config`, `attachments` and `redis` file shares, Key Vault premium (RBAC, purge protection) |
| Network | VNet with apps, Postgres, private-endpoint and ops subnets; deny-by-default NSGs; private endpoints and DNS zones for Key Vault, registry, blob and file; NAT Gateway with one fixed egress IP; VNet flow logs with traffic analytics |
| Identity | Entra app registration (single tenant, assignment required, your security group), managed identities for api, worker, Dataverse and customer-managed keys |
| Delivery | Container Registry Premium, optional jumpbox VM with Azure Bastion Developer, build scripts for Mac or jumpbox |
| Protection | Share soft delete and daily Azure Backup (attachments, redis), delete locks on the stateful resources, diagnostic settings on every resource that has them, metric alerts, Log Analytics (90 days) |

```
Internet ──HTTPS──> api app ingress ──> edge (nginx :8081) ──localhost──> cmd/api (:8080)
                                         │  serves the SPA                  │
                                         │  403 on password login           ├─> Postgres (VNet)
                                         │  outside break_glass_cidrs       ├─> redis app (TCP 6379, in the environment)
                                         │                                  ├─> Key Vault, Files (private endpoints)
                                         │  rate limits auth paths          └─> NAT fixed IP ─> Graph, Dataverse, LLM
worker (no ingress) ───────────────────────────────────────────────────────────┘
```

Staff sign in only with Microsoft (Entra ID): the enterprise app requires
assignment to your security group, and your Conditional Access policy
applies. Guests reach only their scoped links (booking, Deal Room,
unsubscribe), which the app protects with tokens.

## Before you start

- **Azure**: Owner, or Contributor plus User Access Administrator, on the
  target subscription. `az login --tenant <tenant>`,
  `az account set -s <subscription>`, then
  `export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)`: the
  azurerm 4.x provider requires a subscription ID and this stack does not
  hardcode one.
- **Subscription features, once**: encryption at host for the jumpbox
  (or set `encryption_at_host = false`):
  `az feature register --namespace Microsoft.Compute --name EncryptionAtHost`,
  wait until `az feature show` reports `Registered`, then
  `az provider register --namespace Microsoft.Compute`. VNet flow logs need
  Network Watcher in the region (`NetworkWatcher_<region>` in
  `NetworkWatcherRG`), which Azure creates with the first VNet unless the
  subscription opted out.
- **Entra ID**: Application Administrator for whoever runs Terraform (or
  `create_entra_app = false`, see step 2). Conditional Access needs Entra ID
  P1.
- **Tools**: Terraform 1.10 or newer, Azure CLI, `jq`, Docker with buildx
  (Colima on a Mac works) if you build images locally.
- **Margince**: a licence token, and a checkout of the Margince source
  repository at a commit that includes trusted-proxy support
  (`MARGINCE_TRUSTED_PROXIES`). Point `MARGINCE_REPO`
  at it for local image builds: `export MARGINCE_REPO=~/src/margince`.
- **Remote state**: state holds every generated password and the Entra
  client secret. Create a state storage account first (`backend.hcl.example`)
  and never keep state on a laptop.

## 1. Provision (apps off)

```bash
cd standard
cp backend.hcl.example backend.hcl            # fill in
cp terraform.tfvars.example terraform.tfvars  # fill in
terraform init -backend-config=backend.hcl
terraform apply                               # deploy_apps = false
```

`terraform.tfvars` needs at least `image_tag`, `public_base_url`,
`admin_bootstrap_password`, `license_token`, `entra_access_group_object_id`,
`break_glass_cidrs`, `operator_ip_allowlist` (your public IP, from
`curl -s https://api.ipify.org`) and `jumpbox_ssh_public_key`
(`ssh-keygen -t ed25519`; RSA also works).

This creates everything except the Container Apps: network, Key Vault and its
secrets, Postgres, the redis app, storage and shares, registry, private
endpoints, the Entra app and the jumpbox. `operator_ip_allowlist` lets Terraform write
Key Vault secrets and file shares from your machine; it is closed in step 7.

## 2. Entra ID (Entra admin, once)

1. **Admin consent**: Enterprise applications → Margince (`<name_prefix>`) →
   Permissions → Grant admin consent (skip if `entra_grant_admin_consent`).
2. **Conditional Access**: add the app (`terraform output -raw entra_client_id`)
   to the policy that protects Dataverse, so both apps share MFA and device
   rules.
3. **Check access**: Properties → Assignment required = Yes; Users and groups
   lists only your security group.

If Terraform may not create apps, an Entra admin registers one by hand with
the redirect URIs in `terraform output entra_redirect_uris` and the delegated
Graph permissions in `entra.tf`, then set `create_entra_app = false`,
`entra_client_id` and `entra_client_secret`.

## 3. Bootstrap the database (jumpbox, once)

Postgres is reachable only inside the VNet. Open the jumpbox from the Azure
portal (VM `<name_prefix>-jumpbox` → Connect → Bastion → SSH with your private
key), then:

```bash
az login
gh auth login                                 # or read-only deploy keys
git clone <margince repository URL> /opt/margince          # source: cloud builds, bootstrap SQL
git clone <instance repository URL> /opt/margince-instance
cd /opt/margince-instance/deploy/production/azure/standard
cp backend.hcl.example backend.hcl            # same values as on your machine
terraform init -backend-config=backend.hcl

scripts/bootstrap-db.sh                       # default SQL: /opt/margince/scripts/deploy/db-bootstrap.sql
```

`scripts/bootstrap-db.sh` runs the Margince repository's
`scripts/deploy/db-bootstrap.sql` as `pgadmin` over verified TLS, with the
role passwords passed on stdin rather than the command line. Running the SQL
directly with `psql` fails on Flexible Server: `pgadmin` is not a superuser,
so PostgreSQL refuses `ALTER ROLE ... NOSUPERUSER NOBYPASSRLS`, and on
Postgres 16 `CREATE DATABASE ... OWNER margince_owner` fails with "must be
able to SET ROLE". The wrapper replaces those statements with checks that
only alter a role that actually has the attribute, and grants `pgadmin`
membership in `margince_owner` for the duration of the script. It is safe to
rerun. It creates the `margince` database and the `margince_owner` and
`margince_app` roles. The extensions it needs (`vector`, `unaccent`,
`pg_trgm`, `btree_gist`) are already allow-listed by Terraform. Migrations run
later, from the api's entrypoint, with the owner role.

## 4. Build and push the images

`<tag>` must equal `image_tag`. Both ways lock the pushed tags read-only and
print their digests; paste them into `image_digests` to deploy by digest.

**On your Mac** (your IP must be in `operator_ip_allowlist`):

```bash
export MARGINCE_REPO=~/src/margince   # your Margince source checkout
colima start
scripts/build-images.sh local <tag>    # asks: 1) x86 (amd64)  2) ARM (arm64)
```

Choose **x86 (amd64)** for Azure: Container Apps runs `linux/amd64` images
only. **ARM (arm64)** builds native images for running on the Mac, tagged
`margince/<role>:<tag>-arm64`, never used by the deployment. `--arch amd64`
skips the question.

**On the jumpbox**, from your Mac (no allowlist needed; starts the VM if
stopped; fails if the remote build fails):

```bash
scripts/build-images.sh cloud <tag> [git_ref]
```

## 5. Upload `margince.yaml` (once)

```bash
ACCOUNT="$(terraform output -raw storage_account_name)"
KEY="$(az storage account keys list --account-name "$ACCOUNT" --query '[0].value' -o tsv)"
cp "$MARGINCE_REPO/config/margince.example.yaml" margince.yaml
# edit: workspace, bootstrap_admin (password_file: secrets/admin-password),
# seeds.ai_routing for your LLM provider
az storage file upload --account-name "$ACCOUNT" --account-key "$KEY" \
  --share-name "<name_prefix>-config" --source margince.yaml --path margince.yaml
rm margince.yaml
```

## 6. Start the apps, bind the domain

```bash
terraform apply -var deploy_apps=true        # then set it in terraform.tfvars

# DNS, in your zone:
#   CNAME  crm.example.com        -> $(terraform output -raw public_default_fqdn)
#   TXT    asuid.crm.example.com  -> $(terraform output -raw custom_domain_verification_id)
# Zone apex: A record to environment_static_ip, TXT on "asuid".
# A CAA record, if present, must allow: 0 issue digicert.com

terraform apply -var deploy_apps=true -var bind_custom_domain=true
# Issues the free managed certificate and binds it. azurerm 4.x has a managed
# certificate resource, but Azure issues one only for a hostname already on
# an app, and the binding cannot switch to it in place.
az containerapp hostname bind -g "$(terraform output -raw resource_group_name)" \
  -n <name_prefix>-api --hostname crm.example.com \
  --environment <name_prefix>-env --validation-method CNAME   # HTTP for an apex
```

Check the entry point:

```bash
curl -s https://crm.example.com/readyz                        # 200 when dependencies are healthy
curl -s -o /dev/null -w '%{http_code}\n' https://crm.example.com/metrics                   # 404
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://crm.example.com/v1/auth/login     # 403 outside break-glass
```

## 7. First login, then close setup access

1. From a `break_glass_cidrs` address, sign in with the bootstrap admin, set
   the permanent password and keep it as the break-glass account.
2. Turn on Microsoft sign-in in Margince's settings and test it (MFA prompt
   from Conditional Access).
3. Invite staff with the email address they have in Entra.
4. Remove `bootstrap_admin` from `margince.yaml`, set
   `include_bootstrap_admin = false`, add the LLM provider key in
   Settings → AI.
5. Set `operator_ip_allowlist = []` and apply. From now on, run Terraform
   from the jumpbox (`/opt/margince-instance/deploy/production/azure/standard`, backend as in step 3),
   or add your IP back for a single apply.

## 8. Releases

Build with either path in step 4, set `image_tag` (and optionally
`image_digests`), `terraform apply` from the jumpbox. api and worker roll
together; the api startup probe allows five minutes for migrations.

## Dataverse (optional)

- Power Platform admin center → environment → Settings → Application users →
  New app user, using `terraform output -raw dataverse_identity_client_id`,
  with a security role limited to the tables Margince syncs. Application
  users need no licence.
- Managed Environments: add `terraform output -raw nat_egress_ip` to the
  Dataverse IP firewall. The jumpbox shares this address.
- Margince's Dynamics overlay adapter is not built yet; the identity,
  egress IP and `/webhooks/*` route are ready for it.

## Redis

Margince needs Redis 7.0 to 7.2. Azure Cache for Redis Basic and Standard
offer only Redis 6 (and retire on 30 September 2028), so the stack runs the
same `redis:7.2` image Margince develops against, pinned by digest, as a
single-replica container app: internal TCP ingress on 6379, password from Key
Vault, `noeviction` with a `maxmemory` cap, AOF every second on the `redis`
Azure Files share (soft delete and daily backup). AOF on an SMB share is fine
at this scale. For heavier load, or if Margince accepts Redis 7.4, move to
Azure Managed Redis (`azurerm_managed_redis` in azurerm 4.x).

## Cost

Rough list prices in West Europe, per month, before usage-based traffic:

| Item | EUR |
|---|---|
| Container Apps: api (3 replicas), worker, redis | 170-260 |
| Postgres B_Standard_B2s, 64 GiB, backups | 65 |
| Container Registry Premium | 45 |
| NAT Gateway and IP | 35 |
| Private endpoints (4) | 30 |
| Log Analytics, flow logs, traffic analytics | 30-50 |
| Storage (ZRS), Backup, Key Vault | 25-35 |
| Jumpbox (runs on demand), Bastion Developer (free) | 10-25 |
| **Total** | **about 410-545** |

Microsoft recommends General Purpose for production Postgres:
`db_sku_name = "GP_Standard_D2ds_v5"` adds about EUR 75, and
`db_zone_redundant_ha = true` on top adds about EUR 140. Compared with the
earlier stack, the redis app (about EUR 15-25) replaces Azure Cache for Redis
Standard C1 (about EUR 87) and its private endpoint (about EUR 7), and the
third api replica adds about EUR 55.

## Upgrading an existing deployment

This version uses azurerm 4.x. On a stack applied with the 3.x version,
read the plan before applying: the file shares and blob container now use
the Resource Manager API (`storage_account_id`), the jumpbox gains Trusted
Launch, and Azure Cache for Redis is replaced by the redis app (let the
worker drain the outbox first). If the plan replaces a share, move it
instead with `terraform state rm` and `terraform import` using its
Resource Manager ID; the storage lock also refuses the delete.

## Security notes

- **Public surface**: the api app's ingress only, served by the edge
  container. `cmd/api` is reached on localhost; the worker, Redis (internal
  TCP ingress), Postgres, Key Vault, storage and registry have no public
  endpoint once `operator_ip_allowlist` is empty.
- **Sign-in**: password login is refused outside `break_glass_cidrs`; the
  client address comes from Container Apps' rightmost `X-Forwarded-For` entry,
  so clients cannot spoof it. The edge passes it to `cmd/api` as `X-Real-IP`,
  which the api trusts only from `127.0.0.1` (`MARGINCE_TRUSTED_PROXIES`).
- **Secrets**: each app identity may read only the Key Vault secrets its
  process uses. The api app's identities are also available to its edge
  container; keep the web image current.
- **Encryption**: customer-managed key for Postgres and storage (verify both
  can reach the firewalled vault in a test subscription; set
  `postgres_customer_managed_key = false` if Postgres cannot). The registry
  uses Microsoft-managed keys by default. Redis data sits on the storage
  account's `redis` share, under the same key. TLS everywhere except the
  password-protected Redis connection, which never leaves the environment
  (`enable_mtls` encrypts app-to-app traffic, preview).
- **Postgres**: TLS 1.2 minimum, connection throttling after failed logins,
  Entra authentication alongside passwords. Set
  `postgres_entra_admin_object_id` (plus name and type) to add an Entra
  administrator.
- **Logs**: nginx logs paths without query strings and redacts capability
  tokens in public links. Key Vault, blob and file audit logs, NSG events,
  registry logins and backup jobs go to Log Analytics; VNet flow logs go to
  the storage account for 90 days.
- **Jumpbox**: Trusted Launch (secure boot, vTPM), encryption at host,
  platform-managed OS patching, boot diagnostics.
- **Locks**: `CanNotDelete` locks on Postgres, storage, Key Vault, the
  Recovery Services vault and the registry (`enable_resource_locks`). Set it
  to `false` and apply before `terraform destroy`.
- **Images**: build scripts lock pushed tags; `image_digests` pins releases.
  Limit who can run commands on the jumpbox VM.
- **Storage key**: Azure Files SMB mounts need the account key, which is in
  state and in the environment's storage configuration. Rotate it with the
  secondary key on a schedule.

## Known limitations

- **No managed WAF rule set.** Add Azure Front Door in front of the api app
  if edge DDoS absorption, country filtering or managed OWASP rules become a
  requirement.
- **Attachments on Azure Files.** Margince stores attachments with its
  filesystem store on the `attachments` share until a native Azure Blob
  adapter exists. Upload and read back one attachment after the first
  deploy.
- **nginx config is a copy.** `templates/edge-nginx.conf.tftpl`
  replaces the web image's `frontend/nginx.conf` (Margince repository); keep
  their SPA locations in step.
- **Content-Security-Policy is report-only** until the SPA has been checked
  against it.
- **One Entra app** serves sign-in and Graph mail; its client secret rotates
  every 180 days on apply, with a Key Vault near-expiry event 30 days ahead.
- **Redis is one container.** It is not zone-redundant. Container Apps starts
  a new revision before stopping the old one, so an in-place change to the
  redis app (image, resources, command) would briefly run two Redis processes
  on the same `/data` and can corrupt its append-only file. The redis app
  therefore ignores changes to its template: a plain `terraform apply` leaves
  it alone. To change `redis_image`, `redis_memory` or `redis_maxmemory`,
  replace the app, which stops the old Redis before the new one starts (api
  and worker reconnect once Redis is back):

  ```bash
  terraform apply -replace=azurerm_container_app.redis
  ```
- **Needs app changes**: Entra-only Postgres (no passwords), Redis with
  Entra auth (Azure Managed Redis) and a federated credential instead of the
  Entra client secret all require support in Margince first.
- **SMB hardening is off** (`storage_smb_hardening`): Microsoft does not
  document Container Apps mounts with SMB 3.1.1-only, AES-256-GCM and
  NTLMv2. Test it before turning it on.
- **PgBouncer is off.** Flexible Server's built-in PgBouncer (port 6432) is
  optional; enable it only after checking the app's prepared statements work
  through it in transaction mode.

## Tests

```bash
cd standard
terraform init -backend=false
terraform validate
terraform test          # offline plan checks with mocked providers (tests/)
```
