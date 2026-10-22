#!/bin/bash
# Phase 3: Create Azure resources for the POC.
#
# Creates:
#   - Resource Group
#   - Azure Key Vault with RBAC authorization and test secrets
#   - User-Assigned Managed Identity with "Key Vault Secrets User" role
#   - Federated Identity Credential that trusts the SPIRE OIDC issuer
#
# Prerequisites:
#   - az CLI logged in
#   - SPIRE OIDC Discovery Provider route is active
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
NS="zero-trust-workload-identity-manager"

echo "=== Phase 3: Azure Setup ==="
echo ""

# Configuration (override with environment variables before running)
export LOCATION="${LOCATION:-eastus}"
export NAME="${NAME:-ztwimpoc}"
export RESOURCE_GROUP="${RESOURCE_GROUP:-${NAME}-rg}"
export KEYVAULT_NAME="${KEYVAULT_NAME:-${NAME}kv$(openssl rand -hex 3)}"
export USER_ASSIGNED_IDENTITY_NAME="${USER_ASSIGNED_IDENTITY_NAME:-${NAME}-identity}"
export APP_NAMESPACE="${APP_NAMESPACE:-poc-akv-demo}"
export APP_NAME="${APP_NAME:-keyvault-demo}"

# Get OIDC endpoint from the cluster
OIDC_ROUTE=$(oc get route -n "$NS" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
if [ -z "$OIDC_ROUTE" ]; then
    echo "ERROR: Could not find OIDC Discovery Provider route."
    echo "Run Phase 2 first: ./02-deploy-spire.sh"
    exit 1
fi
export JWT_ISSUER_ENDPOINT="$OIDC_ROUTE"

# Get trust domain from SpireServer
TRUST_DOMAIN=$(oc get spireserver cluster -o jsonpath='{.spec.trustDomain}' 2>/dev/null || echo "")
if [ -z "$TRUST_DOMAIN" ]; then
    echo "ERROR: Could not determine SPIRE trust domain."
    exit 1
fi
export APP_DOMAIN="$TRUST_DOMAIN"

# Azure subscription and tenant
export SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export TENANT_ID=$(az account show --query tenantId -o tsv)

echo "Configuration:"
echo "  Location:           $LOCATION"
echo "  Resource Group:     $RESOURCE_GROUP"
echo "  Key Vault:          $KEYVAULT_NAME"
echo "  Managed Identity:   $USER_ASSIGNED_IDENTITY_NAME"
echo "  OIDC Issuer:        https://$JWT_ISSUER_ENDPOINT"
echo "  Trust Domain:       $APP_DOMAIN"
echo "  SPIFFE ID Subject:  spiffe://$APP_DOMAIN/ns/$APP_NAMESPACE/sa/$APP_NAME"
echo "  Subscription:       $SUBSCRIPTION_ID"
echo "  Tenant:             $TENANT_ID"
echo ""

# Step 1: Resource Group
echo "[1/6] Creating Resource Group..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none

# Step 2: Key Vault with RBAC authorization
echo "[2/6] Creating Azure Key Vault (RBAC mode)..."
az keyvault create \
    --name "$KEYVAULT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --enable-rbac-authorization true \
    -o none

export KEYVAULT_URL=$(az keyvault show --name "$KEYVAULT_NAME" --resource-group "$RESOURCE_GROUP" --query properties.vaultUri -o tsv)
export KEYVAULT_RESOURCE_ID=$(az keyvault show --name "$KEYVAULT_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)

# Grant yourself "Key Vault Secrets Officer" so you can create secrets
CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv)
az role assignment create \
    --role "Key Vault Secrets Officer" \
    --assignee-object-id "$CURRENT_USER_ID" \
    --assignee-principal-type User \
    --scope "$KEYVAULT_RESOURCE_ID" \
    -o none 2>/dev/null || echo "  (Role assignment may already exist)"

echo "  Waiting for RBAC propagation (30s)..."
sleep 30

# Step 3: Create test secrets
echo "[3/6] Creating test secrets in Key Vault..."
az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "secret1" --value "Hello-from-SPIFFE-federation" -o none
az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "db-password" --value "super-secret-db-pass-12345" -o none
az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "api-key" --value "ak_live_spiffe_poc_99887766" -o none
echo "  Created: secret1, db-password, api-key"

# Step 4: User-Assigned Managed Identity
echo "[4/6] Creating User-Assigned Managed Identity..."
az identity create \
    --name "$USER_ASSIGNED_IDENTITY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    -o none

export IDENTITY_CLIENT_ID=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$USER_ASSIGNED_IDENTITY_NAME" --query clientId -o tsv)
export IDENTITY_OBJECT_ID=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$USER_ASSIGNED_IDENTITY_NAME" --query principalId -o tsv)

echo "  Identity Client ID: $IDENTITY_CLIENT_ID"

# Step 5: Grant "Key Vault Secrets User" to the managed identity
echo "[5/6] Assigning 'Key Vault Secrets User' role to managed identity..."
az role assignment create \
    --role "Key Vault Secrets User" \
    --assignee-object-id "$IDENTITY_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --scope "$KEYVAULT_RESOURCE_ID" \
    -o none

# Step 6: Federated Identity Credential
echo "[6/6] Creating Federated Identity Credential..."
az identity federated-credential create \
    --name "${NAME}-spiffe-federation" \
    --identity-name "$USER_ASSIGNED_IDENTITY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --issuer "https://$JWT_ISSUER_ENDPOINT" \
    --subject "spiffe://$APP_DOMAIN/ns/$APP_NAMESPACE/sa/$APP_NAME" \
    --audience "api://AzureADTokenExchange" \
    -o none

echo ""
echo "=== Phase 3 complete: Azure resources created ==="
echo ""
echo "  Key Vault URL:    $KEYVAULT_URL"
echo "  Identity Client:  $IDENTITY_CLIENT_ID"
echo "  Federation:       https://$JWT_ISSUER_ENDPOINT"
echo "  SPIFFE Subject:   spiffe://$APP_DOMAIN/ns/$APP_NAMESPACE/sa/$APP_NAME"
echo ""

# Save values for Phase 4
cat > "$BASE_DIR/.env" << ENVEOF
export TENANT_ID="$TENANT_ID"
export IDENTITY_CLIENT_ID="$IDENTITY_CLIENT_ID"
export KEYVAULT_NAME="$KEYVAULT_NAME"
export KEYVAULT_URL="$KEYVAULT_URL"
export APP_NAMESPACE="$APP_NAMESPACE"
export APP_NAME="$APP_NAME"
export APP_DOMAIN="$APP_DOMAIN"
export JWT_ISSUER_ENDPOINT="$JWT_ISSUER_ENDPOINT"
export RESOURCE_GROUP="$RESOURCE_GROUP"
ENVEOF
echo "  Saved to $BASE_DIR/.env (source this for Phase 4)"
