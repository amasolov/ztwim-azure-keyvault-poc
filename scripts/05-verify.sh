#!/bin/bash
# Phase 5: End-to-end verification of the ZTWIM + Azure Key Vault POC.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Load environment
if [ -f "$BASE_DIR/.env" ]; then
    source "$BASE_DIR/.env"
else
    echo "ERROR: $BASE_DIR/.env not found."
    exit 1
fi

NS="zero-trust-workload-identity-manager"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== End-to-End Verification ==="
echo ""

# 1. Check ZTWIM components
echo "--- ZTWIM Operator ---"
oc get csv -n "$NS" -o custom-columns=NAME:.metadata.name,PHASE:.status.phase --no-headers
echo ""

echo "--- SPIRE Components ---"
echo "SPIRE Server:"
oc get statefulset -l app.kubernetes.io/name=spire-server -n "$NS" --no-headers 2>/dev/null || echo "  NOT FOUND"
echo "SPIRE Agent:"
oc get daemonset -l app.kubernetes.io/name=spire-agent -n "$NS" --no-headers 2>/dev/null || echo "  NOT FOUND"
echo "SPIFFE CSI Driver:"
oc get daemonset -l app.kubernetes.io/name=spiffe-csi-driver -n "$NS" --no-headers 2>/dev/null || echo "  NOT FOUND"
echo "OIDC Discovery Provider:"
oc get deployment -l app.kubernetes.io/name=spiffe-oidc-discovery-provider -n "$NS" --no-headers 2>/dev/null || echo "  NOT FOUND"
echo ""

# 2. Verify OIDC endpoint
echo "--- OIDC Discovery Endpoint ---"
OIDC_ROUTE=$(oc get route -n "$NS" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
if [ -n "$OIDC_ROUTE" ]; then
    echo "Route: https://$OIDC_ROUTE"
    echo "Testing discovery document..."
    curl -sk "https://$OIDC_ROUTE/.well-known/openid-configuration" | jq '{issuer, jwks_uri, id_token_signing_alg_values_supported}' 2>/dev/null || echo "  Could not reach endpoint"
    echo ""
    echo "Checking JWKS keys..."
    curl -sk "https://$OIDC_ROUTE/keys" | jq '.keys[] | {kty, alg, use}' 2>/dev/null || echo "  Could not reach keys endpoint"
else
    echo -e "  ${RED}No OIDC route found${NC}"
fi
echo ""

# 3. Check ClusterSPIFFEID
echo "--- ClusterSPIFFEID ---"
oc get clusterspiffeid --no-headers 2>/dev/null || echo "  None configured"
echo ""

# 4. Check demo app
echo "--- Demo Application ---"
POD_NAME=$(oc get pods -n "$APP_NAMESPACE" -l app="$APP_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$POD_NAME" ]; then
    echo "Pod: $POD_NAME"
    POD_STATUS=$(oc get pod "$POD_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.phase}')
    echo "Status: $POD_STATUS"

    if [ "$POD_STATUS" = "Running" ]; then
        echo ""
        echo "--- Fetching JWT-SVID (testing SPIFFE identity) ---"
        oc exec "$POD_NAME" -n "$APP_NAMESPACE" -- python -c "
from spiffe import JwtSource
import json, base64
with JwtSource() as source:
    svid = source.fetch_svid(audience={'api://AzureADTokenExchange'})
    parts = svid.token.split('.')
    header = json.loads(base64.urlsafe_b64decode(parts[0] + '=='))
    payload = json.loads(base64.urlsafe_b64decode(parts[1] + '=='))
    print(f'  Algorithm: {header.get(\"alg\")}')
    print(f'  SPIFFE ID: {payload.get(\"sub\")}')
    print(f'  Audience:  {payload.get(\"aud\")}')
    print(f'  Issuer:    {payload.get(\"iss\")}')
" 2>/dev/null || echo "  Could not fetch SVID (pip dependencies may still be installing)"

        echo ""
        echo "--- Fetching secret from Azure Key Vault ---"
        echo "Running: fetch-kv-secrets.py secret1"
        oc exec "$POD_NAME" -n "$APP_NAMESPACE" -- python /opt/app-root/src/fetch-kv-secrets.py secret1 2>&1 || echo -e "  ${YELLOW}Secret fetch failed (check logs above)${NC}"
    fi
else
    echo -e "  ${RED}Demo pod not found in $APP_NAMESPACE${NC}"
fi

echo ""
echo "=== Verification complete ==="
