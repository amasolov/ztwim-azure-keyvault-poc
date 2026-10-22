#!/bin/bash
# Phase 4: Deploy the demo application that fetches secrets from Azure Key Vault
# using SPIFFE identity federation (no stored credentials).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Load environment from Phase 3
if [ -f "$BASE_DIR/.env" ]; then
    source "$BASE_DIR/.env"
else
    echo "ERROR: $BASE_DIR/.env not found. Run Phase 3 first."
    exit 1
fi

echo "=== Phase 4: Deploying Demo Application ==="
echo ""

# Step 1: Create namespace
echo "[1/4] Creating demo namespace..."
oc apply -f "$BASE_DIR/04-demo-app/namespace.yaml"

# Step 2: Create application secret (Azure config, NOT credentials)
echo "[2/4] Creating application config secret..."
oc apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: $APP_NAME
  namespace: $APP_NAMESPACE
stringData:
  AAD_AUTHORITY: "https://login.microsoftonline.com/"
  AZURE_AUDIENCE: "api://AzureADTokenExchange"
  AZURE_TENANT_ID: "$TENANT_ID"
  AZURE_CLIENT_ID: "$IDENTITY_CLIENT_ID"
  KEYVAULT_NAME: "$KEYVAULT_NAME"
  KEYVAULT_URL: "$KEYVAULT_URL"
EOF

# Step 3: Deploy workload
echo "[3/4] Deploying workload with SPIFFE CSI volume..."
oc apply -f - << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $APP_NAME
  namespace: $APP_NAMESPACE
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $APP_NAME
  namespace: $APP_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $APP_NAME
  template:
    metadata:
      labels:
        app: $APP_NAME
        deployment: $APP_NAME
    spec:
      serviceAccountName: $APP_NAME
      containers:
        - name: $APP_NAME
          image: "registry.redhat.io/ubi9/python-311:latest"
          command:
            - /bin/bash
            - "-c"
            - |
              #!/bin/bash
              set -e
              echo "=== Installing dependencies ==="
              pip install --quiet spiffe azure-identity azure-keyvault-secrets

              cat << 'PYEOF' > /opt/app-root/src/fetch-kv-secrets.py
              #!/opt/app-root/bin/python
              """
              Fetch secrets from Azure Key Vault using SPIFFE JWT-SVID federation.

              Flow:
              1. Get JWT-SVID from SPIFFE Workload API (via CSI-mounted socket)
              2. Exchange it for an Azure Entra ID token (federated credential)
              3. Use the Azure token to read secrets from Key Vault
              """
              import os
              import sys
              from spiffe import JwtSource
              from azure.identity import ClientAssertionCredential
              from azure.keyvault.secrets import SecretClient

              TENANT_ID = os.environ["AZURE_TENANT_ID"]
              CLIENT_ID = os.environ["AZURE_CLIENT_ID"]
              AUDIENCE = os.environ.get("AZURE_AUDIENCE", "api://AzureADTokenExchange")
              KEYVAULT_URL = os.environ["KEYVAULT_URL"]

              def get_spiffe_jwt():
                  """Fetch a JWT-SVID from the local SPIRE agent."""
                  with JwtSource() as source:
                      svid = source.fetch_svid(audience={AUDIENCE})
                      return svid.token

              def main():
                  secret_name = sys.argv[1] if len(sys.argv) > 1 else "secret1"

                  print(f"[1/3] Fetching JWT-SVID from SPIFFE Workload API...")
                  jwt_token = get_spiffe_jwt()
                  print(f"      Got SVID (first 40 chars): {jwt_token[:40]}...")

                  print(f"[2/3] Creating Azure credential via federation...")
                  credential = ClientAssertionCredential(
                      tenant_id=TENANT_ID,
                      client_id=CLIENT_ID,
                      func=get_spiffe_jwt,
                  )

                  print(f"[3/3] Reading secret '{secret_name}' from {KEYVAULT_URL}...")
                  client = SecretClient(vault_url=KEYVAULT_URL, credential=credential)
                  secret = client.get_secret(secret_name)

                  print(f"")
                  print(f"{'='*60}")
                  print(f"  SUCCESS: Secret retrieved via SPIFFE federation!")
                  print(f"  Secret Name:  {secret.name}")
                  print(f"  Secret Value: {secret.value}")
                  print(f"{'='*60}")

              if __name__ == "__main__":
                  main()
              PYEOF

              cat << 'PYEOF2' > /opt/app-root/src/list-kv-secrets.py
              #!/opt/app-root/bin/python
              """List all secrets in Azure Key Vault using SPIFFE federation."""
              import os
              from spiffe import JwtSource
              from azure.identity import ClientAssertionCredential
              from azure.keyvault.secrets import SecretClient

              TENANT_ID = os.environ["AZURE_TENANT_ID"]
              CLIENT_ID = os.environ["AZURE_CLIENT_ID"]
              AUDIENCE = os.environ.get("AZURE_AUDIENCE", "api://AzureADTokenExchange")
              KEYVAULT_URL = os.environ["KEYVAULT_URL"]

              def get_spiffe_jwt():
                  with JwtSource() as source:
                      svid = source.fetch_svid(audience={AUDIENCE})
                      return svid.token

              credential = ClientAssertionCredential(
                  tenant_id=TENANT_ID,
                  client_id=CLIENT_ID,
                  func=get_spiffe_jwt,
              )
              client = SecretClient(vault_url=KEYVAULT_URL, credential=credential)

              print("Secrets in Key Vault:")
              for prop in client.list_properties_of_secrets():
                  print(f"  - {prop.name} (enabled={prop.enabled})")
              PYEOF2

              chmod +x /opt/app-root/src/fetch-kv-secrets.py
              chmod +x /opt/app-root/src/list-kv-secrets.py
              echo ""
              echo "============================================="
              echo "  Demo app ready!"
              echo "  SPIFFE socket: /run/spire/sockets/"
              echo ""
              echo "  Usage:"
              echo "    oc exec -it deploy/$APP_NAME -n $APP_NAMESPACE -- python /opt/app-root/src/fetch-kv-secrets.py secret1"
              echo "    oc exec -it deploy/$APP_NAME -n $APP_NAMESPACE -- python /opt/app-root/src/list-kv-secrets.py"
              echo "============================================="
              while true; do sleep 30; done
          envFrom:
            - secretRef:
                name: $APP_NAME
          env:
            - name: SPIFFE_ENDPOINT_SOCKET
              value: unix:///run/spire/sockets/spire-agent.sock
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            readOnlyRootFilesystem: false
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          ports:
            - containerPort: 8080
              protocol: TCP
          volumeMounts:
            - name: spiffe-workload-api
              mountPath: /run/spire/sockets
              readOnly: true
      volumes:
        - name: spiffe-workload-api
          csi:
            driver: csi.spiffe.io
            readOnly: true
EOF

# Step 4: Wait for pod
echo "[4/4] Waiting for demo pod to start..."
oc rollout status deployment/$APP_NAME -n $APP_NAMESPACE --timeout=300s

echo ""
echo "=== Phase 4 complete: Demo app deployed ==="
echo ""
POD_NAME=$(oc get pods -n $APP_NAMESPACE -l app=$APP_NAME -o jsonpath='{.items[0].metadata.name}')
echo "Pod: $POD_NAME"
echo ""
echo "Next steps:"
echo "  # Fetch a specific secret:"
echo "  oc exec -it $POD_NAME -n $APP_NAMESPACE -- python /opt/app-root/src/fetch-kv-secrets.py secret1"
echo ""
echo "  # List all secrets:"
echo "  oc exec -it $POD_NAME -n $APP_NAMESPACE -- python /opt/app-root/src/list-kv-secrets.py"
echo ""
echo "  # Fetch each test secret:"
echo "  oc exec -it $POD_NAME -n $APP_NAMESPACE -- python /opt/app-root/src/fetch-kv-secrets.py db-password"
echo "  oc exec -it $POD_NAME -n $APP_NAMESPACE -- python /opt/app-root/src/fetch-kv-secrets.py api-key"
