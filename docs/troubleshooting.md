# Troubleshooting

Common issues and debugging steps for the ZTWIM + Azure Key Vault POC.

## Phase 1: ZTWIM Operator Installation

### Operator CSV stuck in "Pending" or "InstallReady"

```bash
# Check the subscription status
oc get subscription -n zero-trust-workload-identity-manager -o yaml

# Check the install plan
oc get installplan -n zero-trust-workload-identity-manager

# Check operator pod logs
oc logs -n zero-trust-workload-identity-manager deployment/zero-trust-workload-identity-manager-controller-manager
```

**Common causes:**
- CatalogSource not reachable (check proxy/firewall for `registry.redhat.io`)
- Install plan requires manual approval (set `installPlanApproval: Automatic`)
- OpenShift version too old (ZTWIM requires 4.18+)

## Phase 2: SPIRE Components

### SPIRE Server pod stuck in CrashLoopBackOff

```bash
oc logs -n zero-trust-workload-identity-manager statefulset/spire-server
```

**Common causes:**
- Invalid `trustDomain` format (must be lowercase alphanumeric, dots, hyphens)
- `jwtIssuer` is not a valid URL (must start with `https://`)
- `caBundleConfigMap` does not exist (it is auto-created, but check timing)

### SPIRE Agent not connecting to server

```bash
oc logs -n zero-trust-workload-identity-manager daemonset/spire-agent
```

**Common causes:**
- `trustDomain` mismatch between SpireServer and SpireAgent
- `clusterName` mismatch between SpireServer and SpireAgent
- SPIRE Server not yet ready when agent starts (should self-resolve on retry)

### SPIFFE CSI Driver pods not starting

```bash
oc get daemonset -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spiffe-csi-driver
oc describe pod -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spiffe-csi-driver
```

**Common causes:**
- `agentSocketPath` mismatch with SpireAgent `socketPath`
- SCC issues (the operator should handle this automatically in supported versions)

### OIDC Discovery Provider returns 5xx

```bash
# Check pod logs
oc logs -n zero-trust-workload-identity-manager deployment/spire-spiffe-oidc-discovery-provider

# Test the endpoint from inside the cluster
oc run curl-test --rm -it --image=registry.access.redhat.com/ubi9/ubi-minimal -- \
    curl -sk https://oidc-discovery.apps.<cluster-domain>/.well-known/openid-configuration
```

**Common causes:**
- `jwtIssuer` mismatch between SpireServer and SpireOIDCDiscoveryProvider
- SPIRE Server not ready (OIDC provider needs to fetch keys from the server)
- Route not created (check `managedRoute: true` in the CR)

## Phase 3: Azure Setup

### Federated credential creation fails

```
ERROR: Issuer URL 'https://...' is not reachable
```

Azure validates the OIDC issuer URL during federated credential creation. The
OIDC Discovery Provider route must be publicly reachable at this point.

**Fix:** Ensure the OIDC route is accessible from the internet. See
[Network Requirements](network-requirements.md).

### "Key Vault Secrets User" role assignment not taking effect

Azure RBAC role assignments can take **up to 10 minutes** to propagate. The
`03-azure-setup.sh` script waits 30 seconds, but in some environments it may
take longer.

```bash
# Verify the role assignment exists
az role assignment list --scope <keyvault-resource-id> --output table
```

## Phase 4: Demo Application

### Pod cannot mount SPIFFE CSI volume

```
Warning  FailedMount  <time>  kubelet  Unable to attach or mount volumes:
    unmounted volumes=[spiffe-workload-api]
```

**Common causes:**
- SPIFFE CSI Driver DaemonSet not running on the node where the pod is scheduled
- `driver: csi.spiffe.io` does not match `pluginName` in the SpiffeCSIDriver CR

```bash
# Verify the CSI driver is registered
oc get csidrivers | grep spiffe
```

### "No identity found" when fetching JWT-SVID

The SPIFFE Workload API returns no identity for the pod.

```bash
# Check if the ClusterSPIFFEID is selecting the pod's namespace
oc get clusterspiffeid -o yaml

# Verify the namespace has the required label
oc get namespace poc-akv-demo --show-labels

# Check SPIRE Server registration entries
oc exec -n zero-trust-workload-identity-manager spire-server-0 -- \
    /opt/spire/bin/spire-server entry show
```

**Common causes:**
- Namespace missing the `spiffe.io/spire-managed-identity: "true"` label
- ClusterSPIFFEID `namespaceSelector` or `podSelector` does not match
- SPIRE Controller Manager not enabled in SpireServer CR

### Azure token exchange fails

```
azure.identity.ClientAssertionCredential: authentication failed
AADSTS700024: Client assertion is not within its valid time range
```

**Common causes:**
- Clock skew between the cluster and Azure (NTP issue)
- JWT-SVID already expired (check `exp` claim)

```
AADSTS70021: No matching federated identity record found
```

**Common causes:**
- SPIFFE ID in the JWT-SVID does not match the `subject` in the federated
  credential
- OIDC issuer URL does not match the `issuer` in the federated credential
- Audience `api://AzureADTokenExchange` not set on both sides

```bash
# Decode and inspect the JWT-SVID
oc exec <pod> -n poc-akv-demo -- python -c "
from spiffe import JwtSource
import json, base64
with JwtSource() as source:
    svid = source.fetch_svid(audience={'api://AzureADTokenExchange'})
    parts = svid.token.split('.')
    header = json.loads(base64.urlsafe_b64decode(parts[0] + '=='))
    payload = json.loads(base64.urlsafe_b64decode(parts[1] + '=='))
    print('Header:', json.dumps(header, indent=2))
    print('Payload:', json.dumps(payload, indent=2))
"
```

Verify that:
- `alg` in the header is `RS256` (not ES256)
- `sub` matches the `subject` in your federated credential
- `iss` matches the `issuer` in your federated credential
- `aud` contains `api://AzureADTokenExchange`

### Azure Key Vault returns 403 Forbidden

The Azure token was obtained successfully, but Key Vault denies access.

**Common causes:**
- The managed identity does not have "Key Vault Secrets User" role on the vault
- The Key Vault uses access policies instead of RBAC (the POC requires RBAC mode)

```bash
# Check the vault's authorization model
az keyvault show --name <vault-name> --query properties.enableRbacAuthorization

# List role assignments on the vault
az role assignment list --scope <keyvault-resource-id> --output table
```

## General Debugging

### View all ZTWIM component statuses

```bash
oc get spireserver,spireagent,spiffecsidriver,spireoidcdiscoveryprovider -A
```

### Operator and component versions

```bash
oc get csv -n zero-trust-workload-identity-manager
```

### Collect all logs

```bash
NS="zero-trust-workload-identity-manager"

echo "=== SPIRE Server ==="
oc logs -n $NS statefulset/spire-server --tail=50

echo "=== SPIRE Agent (first pod) ==="
oc logs -n $NS daemonset/spire-agent --tail=50

echo "=== OIDC Discovery Provider ==="
oc logs -n $NS deployment/spire-spiffe-oidc-discovery-provider --tail=50

echo "=== Operator ==="
oc logs -n $NS deployment/zero-trust-workload-identity-manager-controller-manager --tail=50
```
