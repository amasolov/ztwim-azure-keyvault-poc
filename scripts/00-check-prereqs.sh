#!/bin/bash
# Check that all prerequisites are met before starting the POC.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $desc"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "=== POC Prerequisites Check ==="
echo ""

echo "CLI Tools:"
check "oc CLI installed" command -v oc
check "az CLI installed" command -v az
check "jq installed" command -v jq

echo ""
echo "OpenShift Cluster:"
check "oc logged in" oc whoami
check "cluster-admin role" oc auth can-i '*' '*' --all-namespaces

OCP_VERSION=$(oc version -o json 2>/dev/null | jq -r '.openshiftVersion // "unknown"')
echo -e "  OpenShift version: ${YELLOW}${OCP_VERSION}${NC}"

PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null || echo "unknown")
echo -e "  Platform: ${YELLOW}${PLATFORM}${NC}"

APPS_DOMAIN=$(oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "unknown")
echo -e "  Apps domain: ${YELLOW}${APPS_DOMAIN}${NC}"

echo ""
echo "Azure:"
check "az CLI logged in" az account show
if az account show &>/dev/null; then
    SUB=$(az account show --query name -o tsv 2>/dev/null)
    TENANT=$(az account show --query tenantId -o tsv 2>/dev/null)
    echo -e "  Subscription: ${YELLOW}${SUB}${NC}"
    echo -e "  Tenant ID: ${YELLOW}${TENANT}${NC}"
fi

echo ""
echo "OperatorHub:"
check "ZTWIM operator available in catalog" oc get packagemanifest openshift-zero-trust-workload-identity-manager -n openshift-marketplace

echo ""
echo "=== Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC} ==="

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}Fix the failing checks before proceeding.${NC}"
    exit 1
else
    echo -e "${GREEN}All prerequisites met. Ready to proceed.${NC}"
fi
