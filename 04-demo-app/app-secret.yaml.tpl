# Template: these values are populated by scripts/04-deploy-demo.sh from the
# .env file generated during Phase 3.
#
# NOTE: This secret contains Azure configuration (tenant ID, client ID, vault
# name) but NO credentials. Authentication is handled entirely by the SPIFFE
# JWT-SVID federation. There are no passwords, keys, or tokens stored here.
apiVersion: v1
kind: Secret
metadata:
  name: keyvault-demo
  namespace: poc-akv-demo
stringData:
  AAD_AUTHORITY: "https://login.microsoftonline.com/"
  AZURE_AUDIENCE: "api://AzureADTokenExchange"
  AZURE_TENANT_ID: "${TENANT_ID}"
  AZURE_CLIENT_ID: "${IDENTITY_CLIENT_ID}"
  KEYVAULT_NAME: "${KEYVAULT_NAME}"
  KEYVAULT_URL: "${KEYVAULT_URL}"
