#!/bin/bash
# Cleanup: remove all POC resources from both OpenShift and Azure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
NS="zero-trust-workload-identity-manager"

# Load environment
if [ -f "$BASE_DIR/.env" ]; then
    source "$BASE_DIR/.env"
fi

APP_NAMESPACE="${APP_NAMESPACE:-poc-akv-demo}"
APP_NAME="${APP_NAME:-keyvault-demo}"
RESOURCE_GROUP="${RESOURCE_GROUP:-ztwimpoc-rg}"

echo "=== POC Cleanup ==="
echo ""
echo "This will remove:"
echo "  OpenShift:"
echo "    - Namespace: $APP_NAMESPACE"
echo "    - ClusterSPIFFEID: poc-akv-demo-workloads"
echo "    - SPIRE components (ZeroTrustWorkloadIdentityManager, SpireServer, SpireAgent, SpiffeCSIDriver, SpireOIDCDiscoveryProvider)"
echo "    - ZTWIM operator subscription"
echo "    - Namespace: $NS"
echo "  Azure:"
echo "    - Resource Group: $RESOURCE_GROUP (all resources within)"
echo ""
read -p "Proceed? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "--- OpenShift cleanup ---"

echo "Deleting demo namespace..."
oc delete namespace "$APP_NAMESPACE" --ignore-not-found --wait=false

echo "Deleting ClusterSPIFFEID..."
oc delete clusterspiffeid poc-akv-demo-workloads --ignore-not-found

echo "Deleting SPIRE components..."
oc delete spireoidcdiscoveryprovider cluster --ignore-not-found 2>/dev/null || true
oc delete spiffecsidriver cluster --ignore-not-found 2>/dev/null || true
oc delete spireagent cluster --ignore-not-found 2>/dev/null || true
oc delete spireserver cluster --ignore-not-found 2>/dev/null || true
oc delete zerotrustworkloadidentitymanager cluster --ignore-not-found 2>/dev/null || true

echo "Deleting ZTWIM operator..."
oc delete subscription zero-trust-workload-identity-manager -n "$NS" --ignore-not-found 2>/dev/null || true
CSV=$(oc get csv -n "$NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$CSV" ]; then
    oc delete csv "$CSV" -n "$NS" --ignore-not-found 2>/dev/null || true
fi
oc delete operatorgroup zero-trust-workload-identity-manager -n "$NS" --ignore-not-found 2>/dev/null || true
oc delete namespace "$NS" --ignore-not-found --wait=false

echo ""
echo "--- Azure cleanup ---"
if command -v az &>/dev/null && az account show &>/dev/null 2>&1; then
    echo "Deleting Azure Resource Group: $RESOURCE_GROUP"
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait || echo "  Resource group may not exist"
else
    echo "  az CLI not available or not logged in. Delete manually:"
    echo "    az group delete --name $RESOURCE_GROUP --yes"
fi

echo ""
echo "Cleaning up local files..."
rm -f "$BASE_DIR/.env"

echo ""
echo "=== Cleanup complete ==="
