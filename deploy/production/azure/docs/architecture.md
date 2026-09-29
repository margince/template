# Architecture

Two flavours share the same identity model (Entra ID app registration,
assignment required, Conditional Access) and differ in how the application
runs.

## Light: one VM

```mermaid
flowchart LR
  U["Staff and guests"] -->|HTTPS, Let's Encrypt| N["nginx<br/>SPA, auth rules"]
  subgraph VM["Ubuntu VM (built from source at first boot)"]
    N -->|127.0.0.1:8080| A["margince-api"]
    W["margince-worker"]
    V[("Redis 7.2<br/>localhost")]
    D[("Data disk<br/>attachments, config")]
    A --> V
    W --> V
    A --> D
    W --> D
  end
  A --> PG[("Postgres Flexible B1ms<br/>VNet-only")]
  W --> PG
  VM -. managed identity .-> KV[("Key Vault<br/>secrets")]
  U -. sign in .-> EN["Entra ID"]
```

- **Public surface**: nginx on 80/443; SSH only through Azure Bastion
  Developer.
- **Egress**: the VM's static public IP (allowlist it in a Dataverse IP
  firewall if needed).
- **No high availability**; Postgres keeps 7 days of point-in-time restore.

## Standard: containers

### Overview

```mermaid
flowchart LR
  subgraph Users["Customer"]
    S["Staff<br/>Entra accounts"]
    G["Guests<br/>booking, Deal Room"]
  end
  subgraph MS["Microsoft cloud services"]
    EN["Entra ID<br/>app registration<br/>Conditional Access"]
    GR["Microsoft Graph"]
    DV["Dataverse"]
  end
  subgraph AZ["Your subscription · VNet"]
    subgraph ENV["Container Apps environment"]
      subgraph API["api app (only public ingress)"]
        EDGE["edge · nginx :8081<br/>SPA, auth rules"]
        APP["cmd/api :8080"]
      end
      WK["worker<br/>no ingress"]
    end
    PG[("Postgres Flexible")]
    RD[("Redis 7.2 container<br/>internal TCP")]
    KV[("Key Vault")]
    ST[("Azure Files<br/>config, attachments")]
    ACR[("Container Registry")]
    NAT["NAT Gateway<br/>fixed egress IP"]
    JB["Jumpbox + Bastion<br/>optional"]
  end
  S -->|HTTPS| EDGE
  G -->|HTTPS| EDGE
  S -. sign in .-> EN
  EDGE -->|localhost| APP
  APP --> PG & RD & KV & ST
  WK --> PG & RD & KV & ST
  ACR -. image pull .-> ENV
  APP --> NAT
  WK --> NAT
  NAT --> GR & DV
  JB --> PG
  JB --> ACR
```

- **Public surface**: the api app's ingress only. It targets the edge nginx
  container, which serves the SPA, refuses password login outside the
  break-glass ranges, rate limits authentication paths per client, and
  forwards API paths to `cmd/api` on localhost.
- **Private**: `cmd/api`, the worker, the Redis container (internal TCP only), Postgres (VNet-integrated), Key
  Vault, storage and registry (private endpoints). During setup,
  `operator_ip_allowlist` can open Key Vault, storage and the registry to one
  operator address.
- **Egress**: through the NAT Gateway's single public IP, which a Dataverse IP
  firewall can allowlist.

## Request path

```mermaid
flowchart TD
  C["Browser or MCP client"] -->|HTTPS, managed certificate| I["Container Apps ingress"]
  I --> E["edge nginx"]
  E -->|"/ and /assets"| SPA["SPA files"]
  E -->|"POST /v1/auth/login, not break-glass"| X["403"]
  E -->|"/metrics"| N["404"]
  E -->|"/v1 /webhooks /oauth /mcp /setup"| A["cmd/api, Host preserved, X-Real-IP"]
```

## Staff sign-in

```mermaid
sequenceDiagram
  participant U as Staff
  participant M as Margince
  participant E as Entra ID
  U->>M: Sign in with Microsoft
  M->>E: OIDC with PKCE, tenant pinned
  E->>E: Assigned to the group? Conditional Access
  E-->>M: ID token (tenant and issuer checked)
  M->>M: Match an invited member by email
  M-->>U: Session
```

## Identities

| Identity | Used by | Allowed to |
|---|---|---|
| `api` | api app (cmd/api and edge) | read its own Key Vault secrets, pull images |
| `worker` | worker app | read its own Key Vault secrets, pull images |
| `dataverse` | api and worker | nothing in Azure; registered as a Dataverse application user |
| `data-cmk` | Postgres, storage | wrap and unwrap with the data key |
| jumpbox (system) | jumpbox VM | push images |
| Entra app | staff sign-in, Graph mail and calendar | delegated Graph permissions, assignment required |

## Estimated monthly cost, standard (list prices, West Europe)

| Component | EUR / month |
|---|---|
| Container Apps: api (3 replicas), worker, redis | 170-260 |
| Postgres B2s, 64 GiB, backups | ~65 |
| Container Registry Premium | ~45 |
| NAT Gateway and IP | ~35 |
| Private endpoints (4) and DNS zones | ~33 |
| Log Analytics, flow logs, traffic analytics | 30-50 |
| Storage (ZRS), backup, Key Vault | 25-35 |
| Jumpbox (on demand), Bastion Developer | 10-25 |
| **Total** | **~410-545** |

Excludes bandwidth, LLM usage and licence. Microsoft recommends General
Purpose Postgres for production: `GP_Standard_D2ds_v5` adds about EUR 75,
zone-redundant HA on top about EUR 140.
