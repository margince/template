# Margince on Azure

Terraform root module that deploys Margince into your own Azure subscription
and Entra ID tenant, sized for a small team (about 40 users). It deploys the
images that the template's `make release` builds (Section 4), the same flow as
the AWS standard stack.

## What it creates

| Area | Resources |
|---|---|
| Edge | Application Gateway WAF v2 with a static public IP: the only public entry. TLS with the Key Vault certificate `public_certificate_name`, HTTP to HTTPS redirect, WAF policy (Microsoft Default Rule Set 2.1, Bot Manager 1.1, per-IP rate limits, optional geo allow-list), `waf_mode` count or block. See "WAF rollout". |
| Compute | Container Apps environment (internal: private IP only, workload profiles, Consumption profile, zone-redundant). **api** app (3 to 6 replicas, CPU and HTTP scale rules): `cmd/api` plus an **edge** nginx container that serves the SPA; its ingress is reachable only from the gateway. **worker** app: no ingress. **redis** app: Redis 7.2, one replica, internal TCP only. |
| Data | Postgres Flexible Server 16 (VNet-integrated, customer-managed key, auto-grow, Entra and password auth; single-zone Burstable B2s by default, zone-redundant HA with `db_sku_name` General Purpose and `db_zone_redundant_ha = true`), Storage account with `config`, `attachments` and `redis` file shares, Key Vault premium (RBAC, purge protection) |
| Network | VNet with apps, Postgres, private-endpoint and ops subnets; deny-by-default NSGs; private endpoints and DNS zones for Key Vault, registry, blob and file; NAT Gateway with one fixed egress IP; VNet flow logs with traffic analytics |
| Identity | Entra app registration (single tenant, assignment required, your security group), managed identities for api, worker, Dataverse and customer-managed keys |
| Delivery | Container Registry Premium (images from `make release`), optional jumpbox VM with Azure Bastion Developer |
| Protection | Share soft delete and daily Azure Backup (attachments, redis), delete locks on the stateful resources, diagnostic settings on every resource that has them, metric alerts, Log Analytics (90 days) |

```
Internet ──HTTPS──> Application Gateway WAF v2 ──HTTPS──> api app ingress (private) ──> edge (nginx :8081) ──localhost──> cmd/api (:8080)
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
- **Tools**: Terraform 1.10 or newer, Azure CLI, `jq`; Docker with buildx for
  a manual image push (Section 4).
- **Margince**: a licence token, and this instance repository with its `core/`
  submodule checked out (`git submodule update --init`). The images come from
  `make release`; the bootstrap SQL and `margince.example.yaml` come from
  `core/`, so every stack deploys the core version `instance.yaml` pins.
- **TLS certificate** for the host in `public_base_url`, as a PFX file, to
  import into Key Vault in step 6.
- **Remote state**: state holds every generated password and the Entra
  client secret. Create a state storage account first (`backend.hcl.example`)
  and never keep state on a laptop.

## 1. Provision (apps off)

```bash
cd deploy/production/azure/standard
cp backend.hcl.example backend.hcl            # fill in
cp terraform.tfvars.example terraform.tfvars  # fill in
terraform init -backend-config=backend.hcl
terraform apply                               # deploy_apps = false
```

`terraform.tfvars` needs at least `release_version`, `public_base_url`,
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
git clone --recurse-submodules <instance repository URL> /opt/margince-instance
cd /opt/margince-instance/deploy/production/azure/standard
cp backend.hcl.example backend.hcl            # same values as on your machine
terraform init -backend-config=backend.hcl

scripts/bootstrap-db.sh                       # default SQL: core/scripts/deploy/db-bootstrap.sql
```

`scripts/bootstrap-db.sh` runs core's `scripts/deploy/db-bootstrap.sql` (the
instance repository's `core/` submodule, at the pinned core version) as
`pgadmin` over verified TLS, with the
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

The AWS standard stack uses the same flow. The images are the ones
`make release` (the `release.yml` workflow) or `make package` builds from
core's `Dockerfile`, named `<REGISTRY>/<instance_name>/<role>:<VERSION>`
(the instance repository's `docs/release.md`, Section 6). This stack deploys
`<registry>/<instance_name>/<role>:<release_version>`
(`terraform output image_refs`). Container Apps runs `linux/amd64` images
only, the platform `release.yml` builds by default.

1. Set the image registry. `REGISTRY` is this stack's ACR login server:

   ```sh
   terraform output -raw registry   # <acr_name>.azurecr.io
   ```

   For `release.yml`, set it as the repository variable `REGISTRY`. For a
   manual push, export it in your shell. `instance_name` must equal `name`
   in `instance.yaml`.

2. Log in to the registry. The registry accepts pushes only from
   `operator_ip_allowlist` and the VNet (the jumpbox). GitHub-hosted runners
   are neither, so `release.yml` can push here only from a self-hosted runner
   in the VNet or with the runner's address added to `operator_ip_allowlist`
   for the release. `release.yml` logs in with the repository secrets
   `REGISTRY_USERNAME` and `REGISTRY_PASSWORD`: create a repository-scoped
   token with push rights for them:

   ```sh
   ACR="$(terraform output -raw acr_name)"
   az acr token create -r "$ACR" -n release --repository "<instance_name>/api" content/write content/read \
     --repository "<instance_name>/web" content/write content/read \
     --repository "<instance_name>/worker" content/write content/read
   # use the token name as REGISTRY_USERNAME and one of its passwords as REGISTRY_PASSWORD
   ```

   For a manual push from an allowlisted machine or the jumpbox:

   ```sh
   az acr login -n "$(terraform output -raw acr_name)"
   ```

3. Build and push the release, one of:

   ```sh
   make release VERSION=v0.3.0                      # release.yml builds, tests and pushes
   make package VERSION=v0.3.0 && for role in api web worker; do
     docker push "$REGISTRY/<instance_name>/$role:v0.3.0"
   done                                             # manual push
   ```

4. Lock the pushed tags, the counterpart of the AWS stack's `IMMUTABLE`
   repositories, so a release is never overwritten:

   ```sh
   for role in api web worker; do
     az acr repository update -n "$ACR" --image "<instance_name>/$role:v0.3.0" --write-enabled false
   done
   ```

5. Set `release_version = "v0.3.0"` in `terraform.tfvars` and run
   `terraform apply` (step 6 the first time). api and worker roll together;
   the api startup probe allows five minutes for migrations.

## 5. Upload `margince.yaml` (once)

```bash
ACCOUNT="$(terraform output -raw storage_account_name)"
KEY="$(az storage account keys list --account-name "$ACCOUNT" --query '[0].value' -o tsv)"
cp ../../../../core/config/margince.example.yaml margince.yaml
# edit: workspace, bootstrap_admin (password_file: secrets/admin-password),
# seeds.ai_routing for your LLM provider
az storage file upload --account-name "$ACCOUNT" --account-key "$KEY" \
  --share-name "<name_prefix>-config" --source margince.yaml --path margince.yaml
rm margince.yaml
```

## 6. Start the apps and the gateway

```bash
# DNS, in your zone: an A record for the host in public_base_url
#   crm.example.com  A  $(terraform output -raw public_ip_address)

# The gateway serves the Key Vault certificate public_certificate_name (default
# public-tls). Import it once, from an operator_ip_allowlist address; renewals
# are new versions of the same certificate, which the gateway picks up within
# four hours without an apply.
az keyvault certificate import --vault-name "$(terraform output -raw key_vault_name)" \
  -n public-tls -f crm.example.com.pfx --password '<pfx password>'

terraform apply -var deploy_apps=true        # then set it in terraform.tfvars
```

The first apply with `deploy_apps = true` creates the Container Apps, the
Application Gateway and its WAF diagnostics. The Container Apps environment
is internal: the api app has no public endpoint, and the gateway reaches it
over the VNet through a private DNS zone for the environment's domain.

Check the entry point:

```bash
curl -s https://crm.example.com/readyz                        # 200 when dependencies are healthy
curl -s -o /dev/null -w '%{http_code}\n' https://crm.example.com/metrics                   # 404
curl -s -o /dev/null -w '%{http_code}\n' http://crm.example.com/                          # 301 to HTTPS
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

Follow Section 4 for each new version: `make release VERSION=<v>` (or
`make package` and a manual push), lock the tags, set `release_version` and
run `terraform apply` from the jumpbox or an allowlisted machine.

## WAF rollout

`appgw.tf`'s WAF policy, the counterpart of the AWS standard stack's web ACL
with the same variable names: optional geo allow-list
(`waf_allowed_country_codes`, default off; the provider webhook paths are
always exempt), a per-IP rate limit on the credential endpoints
(`waf_auth_paths`, `waf_auth_rate_limit_per_ip` per 5 minutes), a global
per-IP rate limit (`waf_rate_limit_per_ip` per 5 minutes) that excludes
`/webhooks/gmail|graph|hubspot` (HMAC-verified provider traffic from shared
provider IPs), then the managed rule sets Microsoft Default Rule Set 2.1
(OWASP-based) and Bot Manager 1.1. Request bodies are inspected up to 2000 KB;
file uploads are allowed up to 50 MB.

`waf_mode` defaults to `"count"`: the policy runs in Detection mode and the
custom rules only log. Run like that for about a week of real traffic, then
review what would have been blocked (Log Analytics):

```kusto
AGWFirewallLogs
| where TimeGenerated > ago(7d)
| where Action in ("Matched", "Detected", "Blocked")
| summarize hits = count() by RuleId, Message, RequestUri
| order by hits desc
```

Add an exclusion or a rule override in `appgw.tf` for each false positive
(the commented example there), then set `waf_mode = "block"` (Prevention
mode, custom rules block) and apply. The blocked-requests alert
(`alarms.tf`) reports spikes in either mode. Diagnostics send the firewall
and access logs to Log Analytics for `waf_log_retention_days`.

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

Core pins Redis 7.2 (`redis:7.2@sha256:6461…` in its `docker-compose.dev.yml`).
Azure Cache for Redis Basic and Standard offer only Redis 6 (and retire on
30 September 2028), so the stack runs that exact image, as a
single-replica container app: internal TCP ingress on 6379, password from Key
Vault, `noeviction` with a `maxmemory` cap, AOF every second on the `redis`
Azure Files share (soft delete and daily backup). AOF on an SMB share is fine
at this scale. For heavier load, or if Margince accepts Redis 7.4, move to
Azure Managed Redis (`azurerm_managed_redis` in azurerm 4.x).

## Cost

Rough list prices in West Europe, per month, before usage-based traffic:

| Item | EUR |
|---|---|
| Application Gateway WAF v2 (fixed charge, autoscale from `appgw_min_capacity`) | 250-350 |
| Container Apps: api (3 replicas), worker, redis | 170-260 |
| Postgres B_Standard_B2s, 64 GiB, backups | 65 |
| Container Registry Premium | 45 |
| NAT Gateway and IP | 35 |
| Private endpoints (4) | 30 |
| Log Analytics, flow logs, traffic analytics | 30-50 |
| Storage (ZRS), Backup, Key Vault | 25-35 |
| Jumpbox (runs on demand), Bastion Developer (free) | 10-25 |
| **Total** | **about 660-895** |

Microsoft recommends General Purpose for production Postgres:
`db_sku_name = "GP_Standard_D2ds_v5"` adds about EUR 75, and
`db_zone_redundant_ha = true` on top adds about EUR 140. Compared with the
earlier stack, the redis app (about EUR 15-25) replaces Azure Cache for Redis
Standard C1 (about EUR 87) and its private endpoint (about EUR 7), and the
third api replica adds about EUR 55.

## Upgrading an existing deployment

From the version without the gateway: the Container Apps environment becomes
internal, which Azure applies by replacing the environment and every app in
it, including the redis app (let the worker drain the outbox first). Import
the certificate (step 6) and move the DNS record to `public_ip_address` in
the same window. `image_tag` is now `release_version`, and `bind_custom_domain`
is removed; a plan that still sets either fails with a message.

This version uses azurerm 4.x. On a stack applied with the 3.x version,
read the plan before applying: the file shares and blob container now use
the Resource Manager API (`storage_account_id`), the jumpbox gains Trusted
Launch, and Azure Cache for Redis is replaced by the redis app (let the
worker drain the outbox first). If the plan replaces a share, move it
instead with `terraform state rm` and `terraform import` using its
Resource Manager ID; the storage lock also refuses the delete.

## Security notes

- **Public surface**: the Application Gateway only (WAF v2). The api app's
  ingress is private, in the internal environment. `cmd/api` is reached on localhost; the worker, Redis (internal
  TCP ingress), Postgres, Key Vault, storage and registry have no public
  endpoint once `operator_ip_allowlist` is empty.
- **Sign-in**: password login is refused outside `break_glass_cidrs`; the
  client address comes from the rightmost `X-Forwarded-For` entry, which the
  gateway and Container Apps append, so clients cannot spoof it. The edge passes it to `cmd/api` as `X-Real-IP`,
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
- **Images**: `make release` images, tags locked after the push (Section 4);
  `image_digests` pins releases. Limit who can run commands on the jumpbox VM.
- **Storage key**: Azure Files SMB mounts need the account key, which is in
  state and in the environment's storage configuration. Rotate it with the
  secondary key on a schedule.

## Known limitations

- **Attachments on Azure Files.** Margince stores attachments with its
  filesystem store on the `attachments` share until a native Azure Blob
  adapter exists. Upload and read back one attachment after the first
  deploy.
- **nginx config is a copy.** `templates/edge-nginx.conf.tftpl`
  replaces the web image's `frontend/nginx.conf` (core); keep
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
cd deploy/production/azure/standard
terraform init -backend=false
terraform validate
terraform test          # offline plan checks with mocked providers (tests/)
```
