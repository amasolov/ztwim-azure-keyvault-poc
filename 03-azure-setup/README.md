# Phase 3: Azure Setup

This phase creates the Azure-side resources needed for SPIFFE identity
federation with Azure Key Vault.

## What Gets Created

| Resource | Purpose |
|---|---|
| Resource Group | Container for all POC Azure resources |
| Azure Key Vault | Stores test secrets (RBAC authorization mode) |
| User-Assigned Managed Identity | Azure identity that the workload assumes via federation |
| Role Assignment | "Key Vault Secrets User" on the managed identity, scoped to the vault |
| Federated Identity Credential | Trusts the SPIRE OIDC issuer + SPIFFE ID as a valid identity |

## Variables

Before running the script, export these environment variables (or let the
script use defaults):

```bash
# Your Azure region
export LOCATION="eastus"

# Base name for all resources (used to derive other names)
export NAME="ztwimpoc"

# Override individual names if desired
export RESOURCE_GROUP="${NAME}-rg"
export KEYVAULT_NAME="${NAME}kv<random>"   # auto-generated if not set
export USER_ASSIGNED_IDENTITY_NAME="${NAME}-identity"

# Demo app identifiers (must match the OpenShift deployment)
export APP_NAMESPACE="poc-akv-demo"
export APP_NAME="keyvault-demo"
```

The script will automatically read:
- The **OIDC Discovery Provider route** from the cluster
- The **trust domain** from the ZeroTrustWorkloadIdentityManager CR
- Your Azure **subscription ID** and **tenant ID** from `az account show`

## Run

```bash
../scripts/03-azure-setup.sh
```

## What the Federated Credential Looks Like

The federated credential links three pieces of information:

| Field | Value | Source |
|---|---|---|
| `issuer` | `https://oidc-discovery.apps.<cluster-domain>` | SPIRE OIDC Discovery Provider route |
| `subject` | `spiffe://apps.<cluster-domain>/ns/poc-akv-demo/sa/keyvault-demo` | SPIFFE ID template from ClusterSPIFFEID |
| `audiences` | `["api://AzureADTokenExchange"]` | Standard Azure federated credential audience |

When a workload presents a JWT-SVID with a matching `iss`, `sub`, and `aud`,
Azure issues an access token for the managed identity.
