# mTLS Certificate Validation Issue - Investigation Notes

**Date**: December 5, 2025
**Status**: ⚠️ Partial Success - SPIFFE integration working, mTLS validation failing
**Cluster**: ellinj.teleport.sh

## Executive Summary

The integration between Teleport Workload Identity and Istio is **partially successful**. Teleport successfully issues SPIFFE certificates to workloads, and Istio sidecars receive and load these certificates. However, mTLS peer certificate validation fails when services attempt to communicate, resulting in `CERTIFICATE_VERIFY_FAILED` errors.

## What's Working ✅

### 1. Teleport Workload Identity Infrastructure
- ✅ **tbot DaemonSet**: Running successfully on all nodes (3/3 pods)
- ✅ **Workload API Socket**: Available at `/run/spire/sockets/socket` on each node
- ✅ **Bot Authentication**: Kubernetes join method working with static JWKS
- ✅ **Certificate Issuance**: Teleport issuing short-lived certificates (1 hour TTL)

### 2. SPIFFE ID Issuance
- ✅ **Correct Format**: `spiffe://ellinj.teleport.sh/k8s/<namespace>/<service-account>`
- ✅ **Example IDs**:
  - `spiffe://ellinj.teleport.sh/k8s/sock-shop/front-end`
  - `spiffe://ellinj.teleport.sh/k8s/sock-shop/catalogue`
  - `spiffe://ellinj.teleport.sh/k8s/sock-shop/carts`
- ✅ **Pod Attestation**: Kubernetes service account verification working

### 3. Istio Sidecar Integration
- ✅ **Socket Detection**: Istio proxies detect SPIFFE socket correctly
  ```
  Existing workload SDS socket found at var/run/secrets/workload-spiffe-uds/socket
  Workload is using file mounted certificates
  ```
- ✅ **Certificate Loading**: Envoy loads certificates from Teleport
- ✅ **Trust Domain**: Configured as `ellinj.teleport.sh` (matches Teleport)
- ✅ **Volume Mounts**: hostPath volumes properly configured

### 4. Configuration
- ✅ **Istio Config**: Custom "spire" template applied via annotations
- ✅ **Trust Domain Match**: Both Istio and Teleport using `ellinj.teleport.sh`
- ✅ **Authorization Policies**: Syntax correct with proper SPIFFE ID format

## What's Not Working ❌

### Primary Issue: mTLS Certificate Validation Failure

**Error Message**:
```
upstream connect error or disconnect/reset before headers.
retried and the latest reset reason: remote connection failure,
transport failure reason: TLS_error:|268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end
```

**Symptoms**:
1. External requests to frontend work (LoadBalancer → pod)
2. Service-to-service communication fails (frontend → catalogue)
3. Frontend logs show 200 OK responses (working without mTLS)
4. Direct curl to `/catalogue` returns certificate validation error
5. Error occurs with both STRICT and PERMISSIVE mTLS modes

**Impact**:
- Services cannot communicate using mTLS
- Authorization policies cannot be fully tested
- Zero-trust security model cannot be demonstrated

## Certificate Details

### Certificate Issued by Teleport

Extracted from Envoy in catalogue pod:

```json
{
  "cert_chain": [{
    "path": "<inline>",
    "serial_number": "8b28bde8b8bd4b36f9c193518ec7fe71",
    "subject_alt_names": [{
      "uri": "spiffe://ellinj.teleport.sh/k8s/sock-shop/catalogue"
    }],
    "days_until_expiration": "0",
    "valid_from": "2025-12-05T18:24:35Z",
    "expiration_time": "2025-12-05T19:25:35Z"
  }],
  "ca_cert": [{
    "path": "ellinj.teleport.sh: <inline>",
    "serial_number": "f482fca07c7ae984aea5648ec07e0a5f",
    "days_until_expiration": "3631",
    "valid_from": "2025-11-17T17:51:19Z",
    "expiration_time": "2035-11-15T17:51:19Z"
  }]
}
```

**Observations**:
- Certificate has correct SPIFFE ID in SAN
- Short-lived (1 hour) as expected
- CA certificate present and valid
- Trust chain appears complete

## Configuration Used

### Istio Configuration (istio-config.yaml)

```yaml
meshConfig:
  trustDomain: ellinj.teleport.sh
  pathNormalization:
    normalization: NONE

values:
  sidecarInjectorWebhook:
    templates:
      spire: |
        spec:
          volumes:
          - name: workload-socket
            hostPath:
              path: /run/spire/sockets
              type: Directory
          containers:
          - name: istio-proxy
            volumeMounts:
            - name: workload-socket
              mountPath: /run/secrets/workload-spiffe-uds
              readOnly: true
            env:
            - name: CA_ADDR
              value: unix:///run/secrets/workload-spiffe-uds/socket
            - name: PILOT_CERT_PROVIDER
              value: "workloadapi"
```

### Pod Annotations Required

```yaml
annotations:
  inject.istio.io/templates: "sidecar,spire"
```

### Teleport Workload Identity

```yaml
kind: workload_identity
version: v1
metadata:
  name: istio-workloads
  labels:
    env: dev
spec:
  spiffe:
    id: /k8s/{{ workload.kubernetes.namespace }}/{{ workload.kubernetes.service_account }}
```

**Results in SPIFFE ID**: `spiffe://ellinj.teleport.sh/k8s/<namespace>/<sa>`

### tbot Configuration

```yaml
proxy_server: ellinj.teleport.sh:443
onboarding:
  join_method: kubernetes
  token: istio-tbot-k8s-join
services:
  - type: workload-identity-api
    listen: unix:///run/spire/sockets/socket
    selector:
      name: istio-workloads
    attestors:
      kubernetes:
        enabled: true
        kubelet:
          secure_port: 10250
          token_path: "/var/run/secrets/kubernetes.io/serviceaccount/token"
          ca_path: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
          skip_verify: true
```

## Debugging Steps Taken

### 1. Trust Domain Investigation
- **Initial Issue**: Configured with `cluster.local`
- **Root Cause**: Teleport issues certs with `ellinj.teleport.sh`
- **Fix**: Updated Istio trust domain to match
- **Result**: Trust domain mismatch resolved, but validation still fails

### 2. Authorization Policy Format
- **Initial Issue**: Policies used `cluster.local/k8s/...` format
- **Fix**: Updated to `spiffe://ellinj.teleport.sh/k8s/...`
- **Result**: Policy syntax correct, but can't test due to mTLS failure

### 3. mTLS Mode Testing
- **Tested**: STRICT mode (failed)
- **Tested**: Removed PeerAuthentication (failed)
- **Tested**: PERMISSIVE mode (failed)
- **Result**: Certificate validation fails regardless of mTLS mode

### 4. Certificate Chain Inspection
- **Verified**: CA certificate present in Envoy
- **Verified**: Leaf certificate has correct SPIFFE ID
- **Verified**: Certificate chain appears complete
- **Result**: Certificates load correctly but validation fails

## Possible Root Causes

### 1. Certificate Extension Incompatibility
Teleport-issued certificates may lack specific X.509 extensions that Istio/Envoy expects for mTLS validation.

**Next Steps**:
- Compare certificate extensions between Teleport-issued and Istio-issued certs
- Check for missing Extended Key Usage (EKU) or other critical extensions
- Review Envoy's certificate validation requirements

### 2. Certificate Chain Format
The certificate chain format provided by Teleport's Workload API might not match Envoy's expectations.

**Next Steps**:
- Examine exact format of certificate chain from Workload API
- Compare with SPIRE's certificate format (which Istio is designed to work with)
- Check if Teleport implements SPIFFE Workload API spec exactly

### 3. Trust Bundle Distribution
Envoy might not be correctly receiving or trusting the Teleport CA certificate.

**Next Steps**:
- Verify Envoy's trust bundle configuration
- Check if trust bundle updates are propagating correctly
- Examine Envoy configuration for CA certificate location

### 4. SPIFFE Workload API Implementation Differences
Teleport's implementation of the SPIFFE Workload API may differ from SPIRE's in subtle ways that affect Istio compatibility.

**Next Steps**:
- Compare Teleport's Workload API responses with SPIRE's
- Check SPIFFE Workload API version compatibility
- Review Istio's assumptions about SPIFFE Workload API behavior

## Diagnostic Commands

### Check Certificate in Pod
```bash
kubectl exec -n sock-shop <pod-name> -c istio-proxy -- \
  curl -s localhost:15000/certs | jq
```

### Check Envoy Stats
```bash
kubectl exec -n sock-shop <pod-name> -c istio-proxy -- \
  curl -s localhost:15000/stats | grep tls
```

### Check for mTLS Connections
```bash
kubectl exec -n sock-shop <pod-name> -c istio-proxy -- \
  curl -s localhost:15000/stats | grep "connection_security_policy.mutual_tls"
```

### View Envoy Access Logs
```bash
kubectl logs -n sock-shop <pod-name> -c istio-proxy --tail=100
```

### Test Service Communication
```bash
# From outside the mesh (works without mTLS)
curl http://<FRONTEND_IP>/

# To backend service (fails with mTLS error)
curl http://<FRONTEND_IP>/catalogue
```

## Workaround for Demo

To demonstrate authorization policies and SPIFFE-based access control without full mTLS:

### Option 1: Use Istio's Built-in CA for Sock Shop
Remove the `inject.istio.io/templates: "sidecar,spire"` annotation from sock-shop pods to use Istio's default certificate provider. This allows:
- Full mTLS functionality
- Authorization policies to work
- Demonstrates policy enforcement (but not Teleport integration)

### Option 2: Keep Teleport Integration, Skip mTLS
- Document that SPIFFE ID issuance works
- Show certificates are being issued
- Demonstrate workload attestation
- Note mTLS validation as known issue

### Option 3: Use test-app Deployment
The simple test-app deployment successfully receives Teleport certificates and can be used to demonstrate:
- SPIFFE socket detection
- Certificate issuance
- Pod attestation
- Workload identity lifecycle

## Files Modified for Investigation

### Updated Files
1. `istio-config.yaml` - Changed trust domain to `ellinj.teleport.sh`
2. `sock-shop-demo.yaml` - Added `inject.istio.io/templates` annotation
3. `sock-shop-policies.yaml` - Updated SPIFFE IDs with correct trust domain
4. `sock-shop-permissive-mtls.yaml` - Created for testing PERMISSIVE mode

### Test Commands
```bash
# Verify trust domain
kubectl get configmap istio -n istio-system -o yaml | grep trustDomain

# Check pod annotations
kubectl get deployment -n sock-shop catalogue -o yaml | grep inject.istio.io

# Verify SPIFFE socket
kubectl exec -n sock-shop <pod> -c istio-proxy -- \
  ls -la /var/run/secrets/workload-spiffe-uds/
```

## Comparison: Working vs Non-Working

### test-app (Teleport Certs, No Inter-Service mTLS)
- ✅ SPIFFE socket mounted
- ✅ Certificates loaded
- ✅ Istio proxy detects Teleport certificates
- ⚠️ No service-to-service communication to test

### sock-shop (Teleport Certs, Inter-Service mTLS Required)
- ✅ SPIFFE socket mounted
- ✅ Certificates loaded
- ✅ Istio proxy detects Teleport certificates
- ❌ Service-to-service mTLS validation fails
- ⚠️ External access works (no mTLS required)

## Next Investigation Steps

### 1. Deep Dive on Certificate Format
```bash
# Extract and decode certificate
kubectl exec -n sock-shop <pod> -c istio-proxy -- \
  curl -s localhost:15000/certs | \
  jq -r '.certificates[0].cert_chain[0].path' | \
  openssl x509 -text -noout
```

Compare with Istio-issued certificate format.

### 2. Enable Detailed Envoy Logging
Update Istio proxy log level:
```bash
kubectl exec -n sock-shop <pod> -c istio-proxy -- \
  curl -X POST localhost:15000/logging?level=debug
```

Check logs for detailed TLS handshake errors.

### 3. Consult Teleport Documentation
- Review Teleport's Workload Identity implementation details
- Check known compatibility issues with Istio
- Look for required Istio version or configuration

### 4. Test with SPIRE
As a control test, try the same Istio configuration with SPIRE instead of Teleport to verify the Istio setup is correct.

### 5. Contact Teleport Support
Provide this documentation and ask about:
- Known Istio compatibility issues
- Required Istio configuration
- Certificate format differences from SPIRE
- Recommended Envoy/Istio versions

## References

### Working Configuration
- Trust domain: `ellinj.teleport.sh`
- Istio version: 1.28.0
- Teleport version: 18.5.0
- Kubernetes version: 1.27+

### Key Configuration Files
- `/Users/jeff/dev/istio-tbot/istio-config.yaml`
- `/Users/jeff/dev/istio-tbot/sock-shop-demo.yaml`
- `/Users/jeff/dev/istio-tbot/sock-shop-policies.yaml`
- `/Users/jeff/dev/istio-tbot/tbot-config.yaml`

### Teleport Resources
- Role: `istio-workload-identity-issuer`
- Workload Identity: `istio-workloads`
- Token: `istio-tbot-k8s-join`

## Conclusion

The Teleport Workload Identity integration with Istio successfully demonstrates:
1. ✅ SPIFFE-compliant identity issuance
2. ✅ Pod attestation via Kubernetes
3. ✅ Certificate delivery via SPIFFE Workload API
4. ✅ Istio sidecar integration with external certificate provider

However, mTLS certificate validation between services fails, preventing full zero-trust security demonstration. This appears to be a compatibility issue between Teleport's certificate format/implementation and Istio/Envoy's validation requirements.

**Recommendation**: Contact Teleport support with this documentation to determine if this is a known issue, requires specific configuration, or represents an incompatibility between current versions.
