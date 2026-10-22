# Template: the 04-deploy-demo.sh script renders this with actual values.
#
# Key points about this deployment:
# - Uses the SPIFFE CSI Driver (csi.spiffe.io) to mount the Workload API socket
# - The Python app fetches a JWT-SVID from the socket, exchanges it for an
#   Azure token via ClientAssertionCredential, then reads Key Vault secrets
# - NO credentials are stored in the pod; authentication is purely identity-based
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: keyvault-demo
  namespace: poc-akv-demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keyvault-demo
  namespace: poc-akv-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keyvault-demo
  template:
    metadata:
      labels:
        app: keyvault-demo
        deployment: keyvault-demo
    spec:
      serviceAccountName: keyvault-demo
      containers:
        - name: keyvault-demo
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

              chmod +x /opt/app-root/src/fetch-kv-secrets.py
              echo "=== Ready. Use 'oc exec' to run fetch-kv-secrets.py ==="
              echo "=== Example: python /opt/app-root/src/fetch-kv-secrets.py secret1 ==="
              while true; do sleep 30; done
          envFrom:
            - secretRef:
                name: keyvault-demo
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
        # The SPIFFE CSI Driver mounts the Workload API socket here.
        # This is NOT a persistent volume; it provides the SPIFFE Workload API
        # endpoint for the application to request JWT-SVIDs.
        - name: spiffe-workload-api
          csi:
            driver: csi.spiffe.io
            readOnly: true
