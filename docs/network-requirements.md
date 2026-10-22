# Network Requirements

This document describes the network connectivity required between an on-premises
OpenShift cluster and Microsoft Azure for the ZTWIM + Azure Key Vault POC.

## Overview

The SPIFFE/SPIRE + Azure federation model requires **bidirectional HTTPS
connectivity** between the OpenShift cluster and Azure:

- **Outbound** (cluster to Azure): workloads exchange JWT-SVIDs for Azure
  tokens and call Azure Key Vault APIs.
- **Inbound** (Azure to cluster): Microsoft Entra ID validates JWT-SVIDs by
  fetching the OIDC discovery document and JWKS from the SPIRE OIDC Discovery
  Provider route on the cluster.

## Network Flow Diagram

```
On-Premises Network                           Microsoft Azure
═══════════════════                           ═══════════════

┌─────────────────────┐                 ┌──────────────────────────┐
│  OpenShift Cluster   │                 │  Azure Entra ID          │
│                     │                 │                          │
│  ┌───────────────┐  │   OUTBOUND      │  login.microsoftonline.com│
│  │ Workload Pod  │──│──TCP 443──────►│  (token exchange)        │
│  │               │  │                 │                          │
│  └───────────────┘  │                 └──────────────────────────┘
│                     │
│  ┌───────────────┐  │   OUTBOUND      ┌──────────────────────────┐
│  │ Workload Pod  │──│──TCP 443──────►│  <vault>.vault.azure.net │
│  │               │  │                 │  (Key Vault data plane)  │
│  └───────────────┘  │                 └──────────────────────────┘
│                     │
│  ┌───────────────┐  │   INBOUND       ┌──────────────────────────┐
│  │ OIDC Discovery│◄─│──TCP 443───────│  Azure Entra ID          │
│  │ Provider Route│  │                 │  (JWKS validation)       │
│  └───────────────┘  │                 └──────────────────────────┘
│                     │
│  ┌───────────────┐  │   OUTBOUND      ┌──────────────────────────┐
│  │ OLM / Cluster │──│──TCP 443──────►│  registry.redhat.io      │
│  │ (image pulls) │  │                 │  (operator + app images) │
│  └───────────────┘  │                 └──────────────────────────┘
└─────────────────────┘
```

## Required Firewall Rules

### Outbound (On-Prem Cluster to Internet/Azure)

| # | Source | Destination | Port | Protocol | Purpose |
|---|---|---|---|---|---|
| 1 | Worker/Infra nodes | `login.microsoftonline.com` | 443 | HTTPS | Azure Entra ID token exchange (OAuth2 token endpoint) |
| 2 | Worker/Infra nodes | `<vault-name>.vault.azure.net` | 443 | HTTPS | Azure Key Vault data plane (secret read/list) |
| 3 | Worker/Infra nodes | `management.azure.com` | 443 | HTTPS | Azure Resource Manager (only if using `az` CLI from pods) |
| 4 | All nodes | `registry.redhat.io` | 443 | HTTPS | Pull ZTWIM operator images, UBI base images |
| 5 | All nodes | `registry.access.redhat.com` | 443 | HTTPS | Pull Red Hat container images |
| 6 | All nodes | `quay.io` | 443 | HTTPS | Pull SPIRE component images (if not mirrored) |
| 7 | Admin workstation | `*.azure.com`, `login.microsoftonline.com` | 443 | HTTPS | `az` CLI for Azure resource setup (Phase 3) |

### Inbound (Azure/Internet to On-Prem Cluster)

| # | Source | Destination | Port | Protocol | Purpose |
|---|---|---|---|---|---|
| 8 | Microsoft Entra ID token validation service | OIDC Discovery Provider Route (`*.apps.<cluster-domain>`) | 443 | HTTPS | Azure fetches `/.well-known/openid-configuration` and `/keys` to validate JWT-SVIDs |

> **Rule #8 is critical.** Without it, Azure cannot validate the SPIFFE
> JWT-SVIDs and token exchange will fail. The OIDC route must be reachable from
> the public internet (or at minimum from Azure's token validation
> infrastructure).

### Azure Service Endpoints (FQDNs)

The following Azure FQDNs must be reachable from the cluster:

| FQDN | Service | Notes |
|---|---|---|
| `login.microsoftonline.com` | Entra ID (Azure AD) | OAuth2 token exchange, the workload sends its JWT-SVID here |
| `<vault-name>.vault.azure.net` | Key Vault data plane | Replace with your actual vault name |
| `management.azure.com` | Azure Resource Manager | Only needed for `az` CLI operations during setup |
| `graph.microsoft.com` | Microsoft Graph | May be needed for some identity operations |
| `*.blob.core.windows.net` | Azure Blob Storage | Only if the POC includes Blob Storage access |

### Microsoft Entra ID Source IPs

Azure Entra ID's token validation service makes outbound calls from Azure
datacenters. The source IP ranges rotate and are published in the
[Azure IP Ranges and Service Tags](https://www.microsoft.com/en-us/download/details.aspx?id=56519)
JSON file, under the `AzureActiveDirectory` service tag.

For on-prem firewalls that require specific source IPs, download the latest
service tag JSON and whitelist the `AzureActiveDirectory` ranges for inbound
rule #8.

Alternatively, if your cluster's ingress (the `*.apps` wildcard) is already
exposed to the internet, no additional inbound rules are needed for rule #8.

## OIDC Discovery Provider Route Exposure

The SPIRE OIDC Discovery Provider is exposed via an OpenShift Route under:

```
https://oidc-discovery.apps.<cluster-domain>/
```

Azure must be able to reach two specific paths on this route:

| Path | Response | Purpose |
|---|---|---|
| `/.well-known/openid-configuration` | JSON discovery document | Lists the issuer, JWKS URI, and supported signing algorithms |
| `/keys` | JWKS (JSON Web Key Set) | Contains the public keys Azure uses to verify JWT-SVIDs |

### Exposure Options

| Option | Description | Recommended For |
|---|---|---|
| **Public ingress** | The `*.apps` wildcard DNS already points to a public IP. The OIDC route is accessible alongside other app routes. | Clusters with public-facing ingress (most common) |
| **Dedicated load balancer** | Create a separate Service of type `LoadBalancer` for the OIDC provider, with its own public IP and DNS. | Clusters where `*.apps` is internal-only |
| **Reverse proxy / WAF** | Place a reverse proxy (e.g., Azure Front Door, Cloudflare, on-prem F5) in front of the OIDC route. Only proxy the two paths listed above. | High-security environments requiring L7 filtering |
| **VPN / ExpressRoute** | If the cluster is connected to Azure via VPN or ExpressRoute, configure a private DNS zone so Azure resolves the OIDC route to the VPN-reachable IP. | Hybrid-connected environments |

### TLS Requirements

The OIDC route **must** serve a TLS certificate from a **publicly trusted
Certificate Authority**. Azure Entra ID will reject JWKS responses served over
self-signed or private CA certs.

See [TLS Certificate Options](tls-certificate-options.md) for details on
obtaining and configuring the certificate.

## DNS Requirements

| Record | Value | Notes |
|---|---|---|
| `*.apps.<cluster-domain>` | Cluster ingress IP(s) | Standard OpenShift wildcard; the OIDC route lives here |
| `oidc-discovery.apps.<cluster-domain>` | (Resolved via wildcard) | The OIDC Discovery Provider route hostname |

If the cluster uses split-horizon DNS (internal vs. external), ensure that the
OIDC route hostname resolves to a publicly reachable IP from Azure's
perspective.

## Proxy Considerations

If the cluster uses an HTTP(S) proxy for outbound traffic:

- The proxy must allow HTTPS CONNECT to all Azure FQDNs listed above.
- Set `NO_PROXY` appropriately so intra-cluster traffic (SPIRE Server, Agent,
  CSI Driver) does not route through the proxy.
- The Azure SDK used by the demo app respects `HTTPS_PROXY` and `NO_PROXY`
  environment variables.

## Minimal Connectivity Summary

For the POC to work, at minimum you need:

1. **Outbound HTTPS** from worker nodes to `login.microsoftonline.com` and
   `<vault>.vault.azure.net`
2. **Inbound HTTPS** from Azure to the OIDC Discovery Provider route
   (`oidc-discovery.apps.<cluster-domain>`)
3. **Publicly trusted TLS** on the OIDC route
4. **Outbound HTTPS** to container registries for image pulls (standard
   OpenShift requirement)
