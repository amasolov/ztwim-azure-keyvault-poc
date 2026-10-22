#!/bin/bash
# Phase 2: Deploy SPIRE components in order:
#   SpireServer -> SpireAgent -> SpiffeCSIDriver -> SpireOIDCDiscoveryProvider
#
# IMPORTANT: Deploy in this exact order. Each component depends on the previous one.
#
# Before running this script, update the YAML files in 02-spire-components/
# with your actual cluster domain and cluster name. Replace all occurrences of
# <your-cluster-domain> and <your-cluster-name>.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
NS="zero-trust-workload-identity-manager"

echo "=== Phase 2: Deploying SPIRE Components ==="
echo ""

# Validate that placeholders have been replaced
if grep -q '<your-cluster-domain>' "$BASE_DIR/02-spire-components/01-spire-server.yaml"; then
    echo "ERROR: Placeholders not replaced in SPIRE component manifests."
    echo "Edit the files in 02-spire-components/ and replace:"
    echo "  <your-cluster-domain>  -> your actual cluster apps domain"
    echo "  <your-cluster-name>    -> your cluster name"
    echo ""
    echo "Example:"
    echo "  sed -i 's/<your-cluster-domain>/mycluster.example.com/g' 02-spire-components/*.yaml"
    echo "  sed -i 's/<your-cluster-name>/mycluster/g' 02-spire-components/*.yaml"
    exit 1
fi

# Step 1: SPIRE Server
echo "[1/5] Deploying SPIRE Server..."
oc apply -f "$BASE_DIR/02-spire-components/01-spire-server.yaml"

echo "  Waiting for SPIRE Server StatefulSet..."
for i in $(seq 1 60); do
    READY=$(oc get statefulset -l app.kubernetes.io/name=spire-server -n "$NS" -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "$READY" = "1" ]; then
        echo "  SPIRE Server is ready."
        break
    fi
    echo "  Waiting... ($i/60)"
    sleep 5
done
oc get pods -l app.kubernetes.io/name=spire-server -n "$NS"

# Step 2: SPIRE Agent
echo ""
echo "[2/5] Deploying SPIRE Agent..."
oc apply -f "$BASE_DIR/02-spire-components/02-spire-agent.yaml"

echo "  Waiting for SPIRE Agent DaemonSet..."
for i in $(seq 1 60); do
    DESIRED=$(oc get daemonset -l app.kubernetes.io/name=spire-agent -n "$NS" -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    READY=$(oc get daemonset -l app.kubernetes.io/name=spire-agent -n "$NS" -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo "0")
    if [ "$DESIRED" != "0" ] && [ "$DESIRED" = "$READY" ]; then
        echo "  SPIRE Agent DaemonSet ready ($READY/$DESIRED)."
        break
    fi
    echo "  Waiting... ($i/60) ready=$READY/$DESIRED"
    sleep 5
done
oc get pods -l app.kubernetes.io/name=spire-agent -n "$NS"

# Step 3: SPIFFE CSI Driver
echo ""
echo "[3/5] Deploying SPIFFE CSI Driver..."
oc apply -f "$BASE_DIR/02-spire-components/03-spiffe-csi-driver.yaml"

echo "  Waiting for SPIFFE CSI Driver DaemonSet..."
for i in $(seq 1 60); do
    DESIRED=$(oc get daemonset -l app.kubernetes.io/name=spiffe-csi-driver -n "$NS" -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    READY=$(oc get daemonset -l app.kubernetes.io/name=spiffe-csi-driver -n "$NS" -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo "0")
    if [ "$DESIRED" != "0" ] && [ "$DESIRED" = "$READY" ]; then
        echo "  SPIFFE CSI Driver DaemonSet ready ($READY/$DESIRED)."
        break
    fi
    echo "  Waiting... ($i/60) ready=$READY/$DESIRED"
    sleep 5
done
oc get pods -l app.kubernetes.io/name=spiffe-csi-driver -n "$NS"

# Step 4: OIDC Discovery Provider
echo ""
echo "[4/5] Deploying SPIRE OIDC Discovery Provider..."
oc apply -f "$BASE_DIR/02-spire-components/04-oidc-discovery-provider.yaml"

echo "  Waiting for OIDC Discovery Provider Deployment..."
for i in $(seq 1 60); do
    READY=$(oc get deployment -l app.kubernetes.io/name=spiffe-oidc-discovery-provider -n "$NS" -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "$READY" = "1" ]; then
        echo "  OIDC Discovery Provider is ready."
        break
    fi
    echo "  Waiting... ($i/60)"
    sleep 5
done
oc get pods -l app.kubernetes.io/name=spiffe-oidc-discovery-provider -n "$NS"

# Step 5: ClusterSPIFFEID for auto-registration
echo ""
echo "[5/5] Creating ClusterSPIFFEID for demo namespace..."
oc apply -f "$BASE_DIR/02-spire-components/05-cluster-spiffe-id.yaml"

# Verify OIDC endpoint
echo ""
echo "=== Verifying OIDC Discovery Endpoint ==="
OIDC_ROUTE=$(oc get route -n "$NS" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "NOT_FOUND")
echo "  OIDC Route: https://${OIDC_ROUTE}"

if [ "$OIDC_ROUTE" != "NOT_FOUND" ]; then
    echo "  Testing OIDC discovery document..."
    HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${OIDC_ROUTE}/.well-known/openid-configuration" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        echo "  OIDC endpoint is responding (HTTP 200)."
        curl -sk "https://${OIDC_ROUTE}/.well-known/openid-configuration" | jq . 2>/dev/null || true
    else
        echo "  WARNING: OIDC endpoint returned HTTP $HTTP_CODE."
        echo "  It may take a moment for the route to become active."
    fi
fi

echo ""
echo "=== Phase 2 complete: All SPIRE components deployed ==="
echo ""
echo "Summary of ZTWIM components:"
oc get pods -n "$NS" -o wide
