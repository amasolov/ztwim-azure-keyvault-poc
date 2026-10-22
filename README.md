# Zero Trust Workload Identity Manager + Azure Key Vault POC

A proof-of-concept demonstrating how to fetch secrets from **Azure Key Vault**
and inject them into **OpenShift** workloads using the **Zero Trust Workload
Identity Manager (ZTWIM)** operator, with **no stored credentials**.

ZTWIM is Red Hat's OpenShift operator for [SPIFFE/SPIRE](https://spiffe.io),
providing cryptographically verifiable, short-lived workload identities. This
POC federates those identities with Microsoft Entra ID so that workloads can
access Azure Key Vault using only their SPIFFE identity: no service principal
secrets, no API keys, no long-lived credentials.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  OpenShift Cluster (on-prem or any cloud)                        │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  ZTWIM Operator (zero-trust-workload-identity-manager)   │    │
│  │                                                          │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌────────────────┐   │    │
│  │  │ SPIRE Server│  │ SPIRE Agent │  │ SPIFFE CSI     │   │    │
│  │  │ (issues     │  │ (per-node   │  │ Driver (mounts │   │    │
│  │  │  SVIDs)     │  │  attestor)  │  │  Workload API) │   │    │
│  │  └─────────────┘  └─────────────┘  └────────────────┘   │    │
│  │                                                          │    │
│  │  ┌──────────────────────────┐                            │    │
│  │  │ SPIRE OIDC Discovery    │──── OIDC Route ─────────┐  │    │
│  │  │ Provider (publishes     │  (*.apps.<cluster>)      │  │    │
│  │  │  JWKS for federation)   │                          │  │    │
│  │  └──────────────────────────┘                         │  │    │
│  └───────────────────────────────────────────────────────│──┘    │
│                                                          │       │
│  ┌───────────────────────────────────────────────────┐   │       │
│  │  Demo Namespace                                   │   │       │
│  │  ┌──────────────┐     ┌─────────────────┐         │   │       │
│  │  │ workload-app │     │ csi.spiffe.io   │         │   │       │
│  │  │ (Python)     │◄────│ volume mount    │         │   │       │
│  │  │ 1. Get SVID  │     │ (Workload API   │         │   │       │
│  │  │ 2. Exchange  │     │  socket)        │         │   │       │
│  │  │    for Azure │     └─────────────────┘         │   │       │
│  │  │    token     │                                 │   │       │
│  │  │ 3. Read KV   │                                 │   │       │
│  │  │    secrets   │                                 │   │       │
│  │  └──────┬───────┘                                 │   │       │
│  └─────────│─────────────────────────────────────────┘   │       │
│            │                                             │       │
└────────────│─────────────────────────────────────────────│───────┘
             │ JWT-SVID                                    │ OIDC
             │ (api://AzureADTokenExchange)                │ Trust
             ▼                                             ▼
┌────────────────────────────────────────────────────────────────┐
│  Microsoft Azure / Entra ID                                    │
│                                                                │
│  ┌─────────────────────┐    ┌──────────────────────────────┐   │
│  │ Federated Identity  │    │ User-Assigned Managed        │   │
│  │ Credential          │───►│ Identity                     │   │
│  │                     │    │                              │   │
│  │ issuer: SPIRE OIDC  │    │ Role: Key Vault Secrets User │   │
│  │ subject: SPIFFE ID  │    └──────────────┬───────────────┘   │
│  │ audience: api://... │                   │                   │
│  └─────────────────────┘                   ▼                   │
│                              ┌──────────────────────────┐      │
│                              │ Azure Key Vault          │      │
│                              │  (test secrets)          │      │
│                              └──────────────────────────┘      │
└────────────────────────────────────────────────────────────────┘
```

## How It Works

1. **ZTWIM Operator** deploys SPIRE Server, Agent, SPIFFE CSI Driver, and OIDC
   Discovery Provider on the OpenShift cluster.
2. The **SPIFFE CSI Driver** mounts the Workload API socket into the demo pod
   at `/run/spire/sockets/`.
3. The demo app calls the **SPIFFE Workload API** to obtain a JWT-SVID
   (a short-lived, signed JWT containing the workload's SPIFFE identity).
4. Azure Entra ID validates the JWT-SVID against the **SPIRE OIDC Discovery
   Provider** endpoint (which publishes `/.well-known/openid-configuration`
   and `/keys`).
5. The app exchanges the JWT-SVID for an **Azure access token** via
   `ClientAssertionCredential` (no secrets stored anywhere).
6. The app uses the Azure token to **read secrets from Azure Key Vault**.

## Key Benefits

- **Zero stored credentials**: No service principal secrets, no API keys, no
  long-lived tokens. The workload's identity IS its credential.
- **Short-lived tokens**: JWT-SVIDs expire quickly and are automatically
  refreshed by the SPIRE agent.
- **Platform-agnostic**: Works on bare-metal, VMware, AWS, Azure, GCP, or any
  OpenShift cluster. SPIFFE identities are cloud-independent.
- **Cryptographic attestation**: SPIRE attests the node and workload before
  issuing an identity, providing a hardware root of trust.
- **Standard protocols**: SPIFFE/SPIRE, OIDC federation, Azure RBAC. All
  well-established, auditable standards.

## Prerequisites

| Requirement | Notes |
|---|---|
| OpenShift 4.18+ | ZTWIM is Tech Preview in 4.18-4.19, GA from 4.20+ |
| `cluster-admin` access | Required for operator install and CRD creation |
| Azure subscription | With permissions to create resources, managed identities, federated credentials |
| `az` CLI | Logged in to the target subscription |
| `oc` CLI | Logged in to the cluster as `cluster-admin` |
| `jq` | For JSON processing in scripts |
| Publicly trusted TLS cert | The OIDC Discovery Provider route must serve certs from a public CA (see [Network Requirements](docs/network-requirements.md)) |

## Repository Structure

```
.
├── README.md                           # This file
├── docs/
│   ├── network-requirements.md         # Firewall rules, endpoints, connectivity
│   ├── tls-certificate-options.md      # TLS cert options for OIDC route
│   └── troubleshooting.md             # Common issues and debugging
├── 01-ztwim-operator/
│   └── subscription.yaml               # OLM Subscription for the operator
├── 02-spire-components/
│   ├── 00-trust-manager.yaml           # ZeroTrustWorkloadIdentityManager CR (trust domain)
│   ├── 01-spire-server.yaml            # SpireServer CR
│   ├── 02-spire-agent.yaml             # SpireAgent CR (with node/workload attestors)
│   ├── 03-spiffe-csi-driver.yaml       # SpiffeCSIDriver CR
│   ├── 04-oidc-discovery-provider.yaml # SpireOIDCDiscoveryProvider CR
│   └── 05-cluster-spiffe-id.yaml       # ClusterSPIFFEID for auto-registration
├── 03-azure-setup/
│   └── README.md                       # Azure-side resource creation guide
├── 04-demo-app/
│   ├── namespace.yaml                  # Demo namespace with SPIFFE label
│   ├── app-secret.yaml.tpl             # Template for Azure config (no creds)
│   └── deployment.yaml.tpl             # Template for demo workload
├── scripts/
│   ├── 00-check-prereqs.sh             # Validate prerequisites
│   ├── 01-install-operator.sh          # Install ZTWIM operator
│   ├── 02-deploy-spire.sh              # Deploy all SPIRE components
│   ├── 03-azure-setup.sh               # Create Azure resources
│   ├── 04-deploy-demo.sh               # Deploy demo workload
│   ├── 05-verify.sh                    # End-to-end verification
│   └── 99-cleanup.sh                   # Remove everything
└── .gitignore
```

## Quick Start

```bash
# 1. Check prerequisites
./scripts/00-check-prereqs.sh

# 2. Install the ZTWIM operator
./scripts/01-install-operator.sh

# 3. Deploy SPIRE components (Server, Agent, CSI Driver, OIDC Provider)
./scripts/02-deploy-spire.sh

# 4. Create Azure resources (Key Vault, managed identity, federation)
./scripts/03-azure-setup.sh

# 5. Deploy the demo workload
./scripts/04-deploy-demo.sh

# 6. Verify everything works end-to-end
./scripts/05-verify.sh

# Cleanup when done
./scripts/99-cleanup.sh
```

## Important Notes

- **RS256 signing required**: The SpireServer CR must set `jwtKeyType: rsa-2048`
  (or `rsa-4096`). Microsoft Entra ID only supports RS256-signed tokens; SPIRE
  defaults to ES256 which Azure will reject.
- **Public TLS certificate**: The OIDC Discovery Provider route must serve a
  certificate from a publicly trusted CA. Azure needs to validate the JWKS
  endpoint over HTTPS. See [TLS Certificate Options](docs/tls-certificate-options.md).
- **The SPIFFE CSI Driver mounts the Workload API socket** (not secrets
  directly). The application uses the Azure SDK to fetch Key Vault secrets
  programmatically after exchanging its SVID for an Azure token.
- **Network connectivity**: The on-prem cluster must have outbound HTTPS access
  to Azure endpoints, and Azure must be able to reach the OIDC Discovery
  Provider route. See [Network Requirements](docs/network-requirements.md).

## Quick Start: demo.redhat.com + Personal Azure Account

If you're running this on a **demo.redhat.com** OpenShift environment (AWS)
with your own Azure subscription, the setup is streamlined because the cluster
already has publicly trusted TLS and a public `*.apps` domain.

### 1. Prerequisites

```bash
# Azure: log in and verify permissions
az login
az account show -o table

# OpenShift: log in to the demo cluster (credentials from provisioning email)
oc login --server=https://api.<cluster-domain>:6443 -u <user> -p <password>
```

### 2. Clone and configure

```bash
git clone https://github.com/amasolov/ztwim-azure-keyvault-poc.git
cd ztwim-azure-keyvault-poc

# Get the cluster's apps domain automatically
CLUSTER_DOMAIN=$(oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}')
CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' | cut -d'-' -f1)
echo "Cluster domain: $CLUSTER_DOMAIN"
echo "Cluster name:   $CLUSTER_NAME"

# Replace placeholders in manifests
sed -i.bak "s/<your-apps-domain>/${CLUSTER_DOMAIN}/g" 02-spire-components/*.yaml
sed -i.bak "s/<your-cluster-name>/${CLUSTER_NAME}/g" 02-spire-components/*.yaml
rm -f 02-spire-components/*.yaml.bak
```

### 3. Run

```bash
./scripts/00-check-prereqs.sh      # Verify everything is ready
./scripts/01-install-operator.sh   # Install ZTWIM operator (~2 min)
./scripts/02-deploy-spire.sh       # Deploy SPIRE components (~3 min)
./scripts/03-azure-setup.sh        # Create Azure Key Vault + federation (~2 min)
./scripts/04-deploy-demo.sh        # Deploy demo workload (~2 min)
./scripts/05-verify.sh             # Verify end-to-end
```

### 4. Demo

```bash
# Get the pod name
POD=$(oc get pods -n poc-akv-demo -l app=keyvault-demo -o jsonpath='{.items[0].metadata.name}')

# Fetch a secret from Azure Key Vault using SPIFFE identity (no credentials!)
oc exec -it $POD -n poc-akv-demo -- python /opt/app-root/src/fetch-kv-secrets.py secret1
oc exec -it $POD -n poc-akv-demo -- python /opt/app-root/src/fetch-kv-secrets.py db-password
oc exec -it $POD -n poc-akv-demo -- python /opt/app-root/src/list-kv-secrets.py
```

### 5. Cleanup

```bash
./scripts/99-cleanup.sh   # Removes OpenShift and Azure resources
```

## Architecture Deep Dive

For a detailed explanation of the trust model, identity flow, component
responsibilities, and security properties, see
[Architecture Overview](docs/architecture-overview.md). This document is
intended for system architects evaluating this pattern.

## References

- [OCP 4.22: Zero Trust Workload Identity Manager](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/zero-trust-workload-identity-manager)
- [Red Hat: Zero Trust Workload Identity Manager product page](https://www.redhat.com/en/technologies/cloud-computing/openshift/zero-trust-workload-identity-manager)
- [Microsoft: Federate a SPIFFE/SPIRE workload identity](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-spiffe-spire)
- [SPIFFE.io](https://spiffe.io)
- [GitHub: openshift/zero-trust-workload-identity-manager](https://github.com/openshift/zero-trust-workload-identity-manager)

## License

This POC is provided as-is for demonstration purposes.
