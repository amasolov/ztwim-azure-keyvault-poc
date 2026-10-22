# Architecture Overview for System Architects

This document explains the ZTWIM + Azure Key Vault integration pattern at an
architectural level, covering trust relationships, identity flows, component
responsibilities, and security properties.

## The Problem

Applications running on OpenShift need to access secrets stored in Azure Key
Vault. Traditional approaches require storing Azure credentials (service
principal secrets, API keys, or certificates) inside the cluster as Kubernetes
Secrets. This creates several risks:

- **Credential sprawl**: secrets must be distributed to every namespace that
  needs Azure access
- **Rotation burden**: expired credentials cause outages; manual rotation is
  error-prone
- **Lateral movement risk**: a compromised credential can be used from anywhere,
  not just the intended workload
- **Audit gaps**: it's hard to attribute Azure API calls back to a specific
  workload when credentials are shared

## The Solution: Identity Federation

Instead of storing credentials, this pattern gives each workload a
**cryptographic identity** (a SPIFFE ID) and federates that identity with Azure
Entra ID. The workload authenticates to Azure by proving who it is, not by
presenting a shared secret.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        TRUST RELATIONSHIPS                          │
│                                                                     │
│                    ┌──────────────────┐                              │
│                    │  SPIRE Server    │                              │
│                    │  (Trust Root)    │                              │
│                    └────────┬─────────┘                              │
│                             │ signs                                  │
│                             ▼                                        │
│                    ┌──────────────────┐         ┌────────────────┐   │
│                    │  JWT-SVID        │ ──────► │ Azure Entra ID │   │
│                    │  (workload       │ trusts  │ (validates via │   │
│                    │   identity)      │ via     │  OIDC endpoint)│   │
│                    └──────────────────┘ OIDC    └───────┬────────┘   │
│                                                         │ issues     │
│                                                         ▼            │
│                                                ┌────────────────┐   │
│                                                │ Azure Access   │   │
│                                                │ Token          │   │
│                                                └───────┬────────┘   │
│                                                         │ authorizes │
│                                                         ▼            │
│                                                ┌────────────────┐   │
│                                                │ Azure Key Vault│   │
│                                                └────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

## Component Architecture

### OpenShift Cluster Components

| Component | Type | Count | Responsibility |
|---|---|---|---|
| **ZTWIM Operator** | Deployment | 1 | Manages lifecycle of all SPIRE components; installed via OLM |
| **ZeroTrustWorkloadIdentityManager** | CR | 1 (`cluster`) | Defines the SPIFFE trust domain and cluster name |
| **SPIRE Server** | StatefulSet | 1 | Certificate authority for the trust domain; signs SVIDs; stores registration entries; exposes OIDC keys |
| **SPIRE Agent** | DaemonSet | 1 per node | Attests workloads on the node; serves the Workload API; caches SVIDs |
| **SPIFFE CSI Driver** | DaemonSet | 1 per node | Mounts the Workload API Unix socket into pods as a CSI volume |
| **OIDC Discovery Provider** | Deployment | 1+ | Publishes `/.well-known/openid-configuration` and `/keys` for external OIDC consumers (Azure) |
| **ClusterSPIFFEID** | CR | 1+ | Defines rules for automatic workload registration (which pods get which SPIFFE IDs) |

### Azure Components

| Component | Responsibility |
|---|---|
| **User-Assigned Managed Identity** | Azure identity assumed by the workload; has RBAC role on Key Vault |
| **Federated Identity Credential** | Links the SPIRE OIDC issuer + SPIFFE ID to the managed identity |
| **Azure Key Vault** | Stores secrets; authorizes access via Azure RBAC |
| **Microsoft Entra ID** | Validates JWT-SVIDs by fetching JWKS from the OIDC Discovery Provider; issues Azure access tokens |

## Identity Flow (Step by Step)

```
 Workload Pod            SPIRE Agent         SPIRE Server      OIDC Provider      Entra ID          Key Vault
      │                       │                    │                  │                │                 │
      │  1. Request SVID      │                    │                  │                │                 │
      │──────────────────────►│                    │                  │                │                 │
      │  (via Unix socket)    │                    │                  │                │                 │
      │                       │  2. Verify workload│                  │                │                 │
      │                       │  (k8s attestor     │                  │                │                 │
      │                       │   checks ns/sa)    │                  │                │                 │
      │                       │                    │                  │                │                 │
      │                       │  3. Request signing│                  │                │                 │
      │                       │───────────────────►│                  │                │                 │
      │                       │                    │                  │                │                 │
      │                       │  4. Signed JWT-SVID│                  │                │                 │
      │                       │◄───────────────────│                  │                │                 │
      │                       │                    │                  │                │                 │
      │  5. JWT-SVID          │                    │                  │                │                 │
      │◄──────────────────────│                    │                  │                │                 │
      │                       │                    │                  │                │                 │
      │  6. POST /oauth2/token (with JWT-SVID as client_assertion)   │                │                 │
      │──────────────────────────────────────────────────────────────►│                │                 │
      │                       │                    │                  │                │                 │
      │                       │                    │   7. GET /keys   │                │                 │
      │                       │                    │◄─────────────────│                │                 │
      │                       │                    │   (public keys)  │                │                 │
      │                       │                    │─────────────────►│                │                 │
      │                       │                    │                  │                │                 │
      │                       │                    │                  │  8. Validate   │                 │
      │                       │                    │                  │  JWT signature │                 │
      │                       │                    │                  │  + check sub,  │                 │
      │                       │                    │                  │  iss, aud vs   │                 │
      │                       │                    │                  │  federated     │                 │
      │                       │                    │                  │  credential    │                 │
      │                       │                    │                  │                │                 │
      │  9. Azure access token                                       │                │                 │
      │◄────────────────────────────────────────────────────────────────────────────────│                 │
      │                                                                                                  │
      │  10. GET /secrets/secret1 (with Azure token)                                                     │
      │────────────────────────────────────────────────────────────────────────────────────────────────── ►│
      │                                                                                                  │
      │  11. Secret value                                                                                │
      │◄─────────────────────────────────────────────────────────────────────────────────────────────────│
```

### What Happens at Each Step

| Step | Action | Where | Protocol |
|---|---|---|---|
| 1 | Pod requests a JWT-SVID for audience `api://AzureADTokenExchange` | In-cluster (Unix socket) | SPIFFE Workload API (gRPC) |
| 2 | SPIRE Agent verifies the pod's namespace and service account | In-cluster (Kubernetes API) | k8s API |
| 3-4 | Agent asks Server to sign a JWT with the pod's SPIFFE ID | In-cluster (gRPC) | SPIRE internal |
| 5 | Pod receives a short-lived RS256-signed JWT | In-cluster (Unix socket) | SPIFFE Workload API |
| 6 | Pod sends the JWT-SVID to Azure Entra ID's token endpoint | Outbound HTTPS | OAuth2 client_credentials + client_assertion |
| 7 | Entra ID fetches the JWKS from the OIDC Discovery Provider | Inbound HTTPS to cluster | OIDC discovery |
| 8 | Entra ID validates the JWT signature, issuer, subject, audience | Azure-internal | OIDC validation |
| 9 | Pod receives an Azure access token for the managed identity | Outbound HTTPS response | OAuth2 |
| 10-11 | Pod calls Key Vault with the Azure token; receives secret | Outbound HTTPS | Azure Key Vault REST API |

## SPIFFE Identity Model

Every workload receives a SPIFFE ID based on its Kubernetes namespace and
service account:

```
spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>
```

For example:
```
spiffe://apps.mycluster.example.com/ns/poc-akv-demo/sa/keyvault-demo
```

This identity is:
- **Automatically assigned** by the SPIRE Controller Manager via ClusterSPIFFEID rules
- **Cryptographically attested** (SPIRE verifies the pod is really running in that namespace with that service account)
- **Short-lived** (JWT-SVIDs expire in minutes; X.509-SVIDs in hours)
- **Non-extractable** (the identity is bound to the pod's runtime context; it cannot be stolen and replayed from outside the cluster)

## Security Properties

### What an attacker would need to compromise this flow

| Attack vector | Why it's hard |
|---|---|
| Steal the JWT-SVID | Tokens are short-lived (minutes) and never written to disk; the attacker would need access to the SPIFFE Unix socket, which requires running as the correct service account in the correct namespace |
| Forge a JWT-SVID | Requires the SPIRE Server's private signing key, which is stored in the Server's encrypted datastore |
| Replay a JWT-SVID from outside the cluster | Azure validates the `iss` and `sub` claims; a replayed token only works if it hasn't expired and the attacker can reach `login.microsoftonline.com` |
| Tamper with the OIDC endpoint | The OIDC route serves over TLS with a publicly trusted certificate; DNS hijacking would require compromising the cluster's ingress |
| Escalate to a different SPIFFE ID | SPIRE Agent performs workload attestation; a pod cannot request an SVID for a different namespace/service account |

### Comparison with traditional approaches

| Property | Service Principal Secret | Azure Workload Identity (AKS-native) | ZTWIM (SPIFFE/SPIRE) |
|---|---|---|---|
| Stored credential in cluster | Yes (K8s Secret) | No | No |
| Token lifetime | Long (months/years) | Short (hours) | Short (minutes) |
| Cloud-specific | Azure only | Azure only | **Any cloud, on-prem, edge** |
| Workload attestation | None | Kubernetes SA | SPIRE (node + workload) |
| Cross-cluster federation | Manual | Limited | **Built-in (SPIRE federation)** |
| Standards-based | Proprietary | Azure-specific | SPIFFE/SPIRE (CNCF) |

## Deployment Topology

```
┌─ OpenShift Cluster ──────────────────────────────────────────────┐
│                                                                   │
│  Namespace: zero-trust-workload-identity-manager                  │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │ ZTWIM Operator (Deployment, 1 replica)                      │  │
│  │                                                             │  │
│  │ SPIRE Server (StatefulSet, 1 replica, PVC for SQLite)       │  │
│  │   - Signs SVIDs, manages registrations                      │  │
│  │   - Contains SPIRE Controller Manager sidecar               │  │
│  │                                                             │  │
│  │ SPIRE Agent (DaemonSet, 1 per node)                         │  │
│  │   - Shares /run/spire/agent-sockets via hostPath            │  │
│  │   - NodeAttestor: k8s_psat (projected service account token)│  │
│  │   - WorkloadAttestor: k8s (verifies pod ns/sa via API)      │  │
│  │                                                             │  │
│  │ SPIFFE CSI Driver (DaemonSet, 1 per node)                   │  │
│  │   - Mounts agent socket into pods as ephemeral CSI volume   │  │
│  │                                                             │  │
│  │ OIDC Discovery Provider (Deployment, 1 replica)             │  │
│  │   - Exposed via OpenShift Route (reencrypt TLS)             │  │
│  │   - Serves /.well-known/openid-configuration and /keys      │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  Namespace: poc-akv-demo (or any application namespace)           │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │ Application Pod                                             │  │
│  │   - ServiceAccount: keyvault-demo                           │  │
│  │   - CSI volume: csi.spiffe.io (Workload API socket)         │  │
│  │   - Uses spiffe + azure-identity + azure-keyvault SDKs      │  │
│  │   - Environment: TENANT_ID, CLIENT_ID, KEYVAULT_URL         │  │
│  │     (configuration only, NO credentials)                    │  │
│  └─────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────┘
```

## Extending This Pattern

### Other Azure services

The same federation mechanism works for any Azure service that accepts Entra ID
tokens: Azure Blob Storage, Azure SQL, Azure Container Registry, Azure Service
Bus, Cosmos DB, and more. Just change the RBAC role on the managed identity.

### Multiple workloads

Each workload (namespace + service account combination) can have its own
federated credential on the same or different managed identities, with different
RBAC scopes. The ClusterSPIFFEID automatically registers new workloads.

### Multi-cluster

SPIRE supports federation between trust domains. Two OpenShift clusters running
ZTWIM can exchange trust bundles, allowing workloads in Cluster A to verify
identities from Cluster B. Combined with Azure federation, this enables
cross-cluster access to shared Azure resources.

### Other secret stores

The SPIFFE identity is not Azure-specific. The same JWT-SVID can be used to
authenticate to HashiCorp Vault (via its JWT auth method), AWS (via OIDC
federation), GCP (via Workload Identity Federation), or any OIDC-aware system.

## Key Design Decisions

| Decision | Rationale |
|---|---|
| **SQLite datastore** | Sufficient for POC/small clusters; production should use PostgreSQL for HA |
| **RSA-2048 JWT key type** | Required by Azure Entra ID; SPIRE defaults to ES256 which Azure rejects |
| **Managed OIDC route** | Simplest option; the operator creates and manages the OpenShift Route automatically |
| **ClusterSPIFFEID with namespace selector** | Opt-in model: only namespaces with the label `spiffe.io/spire-managed-identity: "true"` get identities |
| **User-assigned managed identity** (not app registration) | Simpler Azure permissions; no Entra ID admin roles required |
| **Key Vault RBAC mode** | Modern approach; uses Azure RBAC instead of legacy vault access policies |
