#!/bin/bash
# Phase 1: Install the Zero Trust Workload Identity Manager operator via OLM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Phase 1: Installing ZTWIM Operator ==="
echo ""

echo "[1/3] Applying operator subscription..."
oc apply -f "$BASE_DIR/01-ztwim-operator/subscription.yaml"

echo "[2/3] Waiting for operator to install (up to 5 minutes)..."
for i in $(seq 1 60); do
    CSV=$(oc get csv -n zero-trust-workload-identity-manager -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
    if [ "$CSV" = "Succeeded" ]; then
        CSV_NAME=$(oc get csv -n zero-trust-workload-identity-manager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        echo "  Operator CSV '$CSV_NAME' is ready."
        break
    fi
    echo "  Waiting... ($i/60) status=$CSV"
    sleep 5
done

if [ "$CSV" != "Succeeded" ]; then
    echo "ERROR: Operator did not reach 'Succeeded' state in 5 minutes."
    echo "Check: oc get csv -n zero-trust-workload-identity-manager"
    exit 1
fi

echo "[3/3] Verifying operator pods..."
oc get pods -n zero-trust-workload-identity-manager

echo ""
echo "=== Phase 1 complete: ZTWIM Operator installed ==="
