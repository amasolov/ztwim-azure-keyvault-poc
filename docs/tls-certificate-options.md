# TLS Certificate Options for the OIDC Discovery Provider

The SPIRE OIDC Discovery Provider route **must** serve a TLS certificate from a
publicly trusted Certificate Authority (CA). Microsoft Entra ID validates the
JWKS endpoint over HTTPS and will reject self-signed or private CA certificates.

This document outlines the available options for obtaining and configuring TLS
certificates for the OIDC route.

## Option 1: Cluster Ingress Certificate (Easiest)

If your OpenShift cluster's default ingress controller already uses a publicly
trusted certificate (e.g., from Let's Encrypt, DigiCert, or your enterprise
CA that is publicly trusted), the OIDC Discovery Provider route will
automatically inherit this certificate.

**Check your current ingress cert:**

```bash
# View the default ingress certificate
oc get secret router-certs-default -n openshift-ingress -o jsonpath='{.data.tls\.crt}' | \
    base64 -d | openssl x509 -noout -issuer -subject -dates
```

If the issuer is a publicly trusted CA, you're all set. No additional
configuration is needed.

## Option 2: Let's Encrypt with cert-manager

Install [cert-manager](https://cert-manager.io/) on the cluster and configure
it to issue Let's Encrypt certificates for the OIDC route.

1. Install cert-manager operator from OperatorHub
2. Create a `ClusterIssuer` for Let's Encrypt:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: openshift-default
```

3. Create a `Certificate` for the OIDC route:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: oidc-discovery-tls
  namespace: zero-trust-workload-identity-manager
spec:
  secretName: oidc-discovery-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - oidc-discovery.apps.<your-cluster-domain>
```

4. Reference the secret in the OIDC Discovery Provider CR:

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: SpireOIDCDiscoveryProvider
metadata:
  name: cluster
spec:
  jwtIssuer: "https://oidc-discovery.apps.<your-cluster-domain>"
  replicas: 1
  managedRoute: true
  externalSecretRef: "oidc-discovery-tls"
```

## Option 3: External Certificate (Manual)

If you have a certificate from your enterprise CA or another provider:

1. Create a TLS secret in the ZTWIM namespace:

```bash
oc create secret tls oidc-discovery-tls \
    --cert=path/to/tls.crt \
    --key=path/to/tls.key \
    -n zero-trust-workload-identity-manager
```

2. Reference it in the `SpireOIDCDiscoveryProvider` CR using `externalSecretRef`.

**Important:** The certificate's Subject Alternative Name (SAN) must include
the OIDC route hostname (e.g., `oidc-discovery.apps.<your-cluster-domain>`).

## Option 4: Reverse Proxy Termination

Place a publicly accessible reverse proxy (Azure Front Door, Cloudflare,
on-prem F5/HAProxy) in front of the OIDC route:

1. Disable the managed route:

```yaml
spec:
  managedRoute: false
```

2. Create a manual route or expose the service:

```bash
oc expose service spire-spiffe-oidc-discovery-provider \
    --hostname=oidc-discovery.your-public-domain.com \
    -n zero-trust-workload-identity-manager
```

3. Configure the reverse proxy to terminate TLS with a publicly trusted cert
   and forward traffic to the OpenShift ingress.

4. Set the `jwtIssuer` in the SpireServer and SpireOIDCDiscoveryProvider CRs
   to match the public hostname served by the proxy.

## Verifying the TLS Certificate

After configuration, verify the certificate is correct:

```bash
# Get the OIDC route hostname
OIDC_HOST=$(oc get route -n zero-trust-workload-identity-manager \
    -o jsonpath='{.items[0].spec.host}')

# Test the OIDC endpoint and show the certificate chain
curl -v "https://${OIDC_HOST}/.well-known/openid-configuration" 2>&1 | \
    grep -E "subject:|issuer:|expire"

# Verify the full chain is trusted (should show "SSL certificate verify ok")
curl -sS "https://${OIDC_HOST}/.well-known/openid-configuration" > /dev/null && \
    echo "TLS OK: certificate is publicly trusted" || \
    echo "TLS FAIL: certificate is NOT publicly trusted"
```

The last command must succeed **without** the `-k` (insecure) flag. If it fails
without `-k`, Azure will also reject the certificate.

## Common Pitfalls

| Issue | Symptom | Fix |
|---|---|---|
| Self-signed default ingress cert | Azure token exchange fails with "OIDC issuer validation error" | Use one of the options above to deploy a publicly trusted cert |
| Certificate SAN mismatch | Azure returns "invalid issuer" | Ensure the cert's SAN includes the exact OIDC route hostname |
| Expired certificate | Intermittent "OIDC issuer" errors | Set up automatic renewal (cert-manager handles this) |
| Intermediate CA missing | Azure rejects the cert even though browsers accept it | Include the full certificate chain (not just the leaf cert) in the TLS secret |
| Split-horizon DNS | Azure resolves the OIDC hostname to an internal IP | Ensure external DNS resolves to a publicly reachable ingress IP |
