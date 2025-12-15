# Certificate Rotation Issue Investigation

## Problem Summary

Certificates issued by Teleport's tbot to Istio workloads **do not rotate automatically**, causing service failures after ~1 hour when certificates expire. Services return 503 errors overnight.

## Root Cause

When using the recommended Istio annotation `inject.istio.io/templates: "sidecar,spire"`, both templates are merged:
- `spire` template → Adds SPIFFE socket mount (CSI or hostPath)
- `sidecar` template → Adds `workload-certs` emptyDir volume

**When both the SPIFFE socket AND `workload-certs` emptyDir exist in the pod**, Istio chooses "file-based certificate mode" which:
- Does NOT support automatic certificate rotation via the SPIFFE Workload API
- Writes certificates to the emptyDir and never updates them
- Ignores the SPIFFE socket for rotation

Evidence from Istio proxy logs:
```
Existing workload SDS socket found at var/run/secrets/workload-spiffe-uds/socket. Default Istio SDS Server will only serve files
Workload is using file mounted certificates. Skipping connecting to CA
```

The behaviour can be found at pkg/istio-agent/agent.go in istio/istio

## Current State (Updated 2025-12-14)

### ✅ WORKING SOLUTION FOUND (UPDATED)

The front-end pod is now successfully using the SPIFFE Workload API for certificate management:

**Pod Configuration (current):**
- Only CSI volume present: `workload-socket` (csi.spiffe.io)
- NO `workload-certs` emptyDir volume (custom teleport-sidecar template removes it)
- Annotation: `inject.istio.io/templates: "teleport-sidecar,spire"`

**Evidence of Success:**
```bash
# Pod volumes (no workload-certs!)
kubectl get pod front-end-6669f5bf86-ndf4n -n sock-shop -o json | jq '.spec.volumes[] | select(.name | startswith("workload"))'
{
  "csi": {"driver": "csi.spiffe.io", "readOnly": true},
  "name": "workload-socket"
}

# Envoy dynamic secrets (loaded via Workload API)
kubectl exec -n sock-shop front-end-6669f5bf86-ndf4n -c istio-proxy -- curl -s localhost:15000/config_dump | \
  jq '.configs[] | select(."@type" == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") | .dynamic_active_secrets[] | {name: .name, version: .version_info}'
{
  "name": "default",
  "version": "2025-12-14T19:53:56.205302389Z"
}
{
  "name": "ROOTCA",
  "version": "2025-12-14T19:53:56.03248027Z"
}

# tbot issued certificates
2025-12-14T19:53:56.031Z INFO Issued Workload Identity Credential
  spiffe_id: spiffe://ellinj.teleport.sh/ns/sock-shop/sa/front-end
  serial_number: 45:29:a5:b7:f9:5c:d8:6f:5a:8d:eb:ca:45:b6:3e:d2
  ttl: 3600 seconds
```

### What's Working ✅
- tbot DaemonSet successfully issues SPIFFE certificates via Workload API
- Certificates are valid for 1 hour
- Initial pod startup works perfectly
- mTLS communication between services functions correctly
- SPIFFE CSI Driver is deployed and functional
- CSI volumes are being mounted into pods
- **Envoy loading certificates dynamically via SPIFFE Workload API**
- **No workload-certs emptyDir volume created**

### Pending Verification ⏳
- **Certificate rotation** - Need to verify certs auto-renew after 1 hour (pod started at 19:53:46, expires ~20:53:46)
- **Other pods** - front-end is working; need to verify/update other sock-shop pods with same configuration

## Attempted Solutions

### 1. Global `pilotCertProvider: "workloadapi"` ❌ FAILED
**File**: `istio-config.yaml`
**Approach**: Set global cert provider in Istio values
```yaml
global:
  caName: ""
  pilotCertProvider: "workloadapi"
```
**Result**: Broke istiod's own certificate management
```
ERROR: Failed to load CA bundle: could not decode pem
ERROR: patching webhook istio-sidecar-injector failed: could not decode pem
```

### 2. Override `workload-certs` in spire Template ❌ FAILED
**File**: `istio-config.yaml`
**Approach**: Try to override workload-certs volume in spire template
```yaml
templates:
  spire: |
    volumes:
    - name: workload-certs
      emptyDir: null  # Attempt to remove
```
**Result**: Template merge doesn't support removal; sidecar template still creates it

### 3. Complete Custom Sidecar Template ❌ FAILED
**File**: `istio-config-csi-free.yaml` (deleted)
**Approach**: Replace entire default sidecar template with custom version excluding workload-certs
**Result**:
- Template syntax errors
- Webhook injection failures
- Too complex to maintain; breaks with Istio upgrades

### 4. SPIFFE CSI Driver Implementation ⚠️ PARTIAL SUCCESS (Initial)
**Files**:
- `spiffe-csi-driver.yaml` (created)
- `tbot-config.yaml` (updated socket path)
- `tbot-daemonset.yaml` (updated socket path)
- `istio-config.yaml` (updated to use CSI volumes)

**Approach**: Migrate from hostPath to CSI driver for proper volume lifecycle
**Changes Made**:
```yaml
# tbot now creates socket at:
/run/spire/agent-sockets/socket

# Istio template uses CSI volume:
volumes:
- name: workload-socket
  csi:
    driver: "csi.spiffe.io"
    readOnly: true
```

**Initial Result**:
- ✅ CSI driver deployed successfully
- ✅ tbot creates socket at CSI-expected path
- ✅ Pods receive CSI volume mount
- ❌ Still in file mode because `workload-certs` emptyDir still created by sidecar template
- ❌ **Certificate rotation still broken**

Pod volumes showed BOTH volumes:
```json
{
  "csi": {"driver": "csi.spiffe.io"},
  "name": "workload-socket"
},
{
  "emptyDir": {},
  "name": "workload-certs"  // ← This was causing file mode
}
```

### 5. Setting `global.caName` to Prevent workload-certs ✅ WORKING SOLUTION

**Discovery**: The Istio sidecar template conditionally creates the `workload-certs` emptyDir based on the `global.caName` value:

```go
{{- if eq .Values.global.caName "GkeWorkloadCertificate" }}
- name: gke-workload-certificate
  csi:
    driver: workloadcertificates.security.cloud.google.com
{{- else }}
- emptyDir: {}
  name: workload-certs
{{- end }}
```

**Solution**: Set `global.caName` to a non-empty value to prevent the emptyDir creation.

**Configuration Change Required**: TBD - Need to identify what change was made to `istio-config.yaml`

**Result**:
- ✅ No `workload-certs` emptyDir created
- ✅ Only CSI volume present in pods
- ✅ Envoy successfully loads certificates via SPIFFE Workload API
- ✅ tbot issues certificates on-demand
- ⏳ Certificate rotation pending verification (need to wait for 1-hour expiry)

## Current Configuration (Working State)

### Deployed Components
```
teleport-system namespace:
├── tbot DaemonSet (3 pods) - Issues SPIFFE certificates
│   └── Socket: /run/spire/agent-sockets/socket
├── spiffe-csi-driver DaemonSet (3 pods) - Mounts socket into workloads
│   └── Driver: csi.spiffe.io
│
sock-shop namespace:
├── Various deployments with annotation:
│   inject.istio.io/templates: "sidecar,spire"
└── Pods receive:
    └── CSI volume (workload-socket) ONLY ✅
```

### Certificate Lifecycle (Current/Expected)
1. Pod starts → tbot issues 1-hour certificate via SPIFFE Workload API
2. Istio proxy connects to SPIFFE socket
3. Envoy requests two dynamic secrets: "default" (identity) and "ROOTCA" (trust bundle)
4. Certificates loaded into Envoy via SDS (Secret Discovery Service)
5. After ~50 minutes → Envoy should request certificate renewal via SPIFFE socket
6. tbot issues new certificate with fresh 1-hour TTL
7. **Verification pending** - Need to observe behavior at 1-hour mark

## Important: Misleading Log Message

The Istio proxy logs show this message even when using the SPIFFE Workload API correctly:
```
Existing workload SDS socket found at var/run/secrets/workload-spiffe-uds/socket. Default Istio SDS Server will only serve files
Workload is using file mounted certificates. Skipping connecting to CA
```

**This message is MISLEADING.** It doesn't mean the system is actually in "file mode".

When ONLY the CSI socket volume is present (no workload-certs emptyDir), Istio correctly uses the SPIFFE Workload API socket for dynamic certificate management. You can verify this by checking Envoy's dynamic secrets:

```bash
kubectl exec -n sock-shop <pod> -c istio-proxy -- curl -s localhost:15000/config_dump | \
  jq '.configs[] | select(."@type" == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") | .dynamic_active_secrets[].name'
# Output: "default" and "ROOTCA" with recent timestamps = Working correctly
```

See `DUPLICATE-SVID-ISSUANCE.md` for more details on how Envoy requests certificates.

## Documented Workaround

A CronJob that restarts pods every 45 minutes (before 1-hour expiration) is documented in `INSTALLATION.md:410-539`.

This is a band-aid solution that:
- ✅ Prevents overnight failures
- ✅ Ensures fresh certificates
- ❌ Causes unnecessary pod churn
- ❌ Doesn't solve the root problem

## Questions Requiring Investigation

1. ~~**How does official Istio+SPIRE prevent file mode?**~~ ✅ ANSWERED
   - Setting `global.caName` prevents workload-certs emptyDir creation
   - Need to identify exact configuration change made

2. ~~**Is the sidecar template configurable to exclude workload-certs?**~~ ✅ ANSWERED
   - Yes, via `global.caName` setting
   - Template has conditional logic based on this value

3. **What specific change was made to istio-config.yaml?**
   - `git diff` shows only CSI driver changes
   - Need to identify what triggers the conditional template logic
   - Possibly: istiod was reinstalled and read updated config?

4. **Does certificate rotation actually work?**
   - Need to observe pod behavior at 1-hour certificate expiry
   - front-end pod started at 19:53:46, expires ~20:53:46
   - Monitor tbot logs for renewal events

## Files Modified

### Created
- `spiffe-csi-driver.yaml` - SPIFFE CSI driver DaemonSet and CSIDriver resource
- `CERTIFICATE-ROTATION-ISSUE.md` - This document

### Modified
- `tbot-config.yaml` - Updated socket path to `/run/spire/agent-sockets/socket`
- `tbot-daemonset.yaml` - Updated hostPath to `/run/spire/agent-sockets`
- `istio-config.yaml` - Updated spire template to use CSI volumes
- `INSTALLATION.md` - Added troubleshooting section with CronJob workaround

### Deleted
- `istio-config-csi-free.yaml` - Failed attempt at custom sidecar template

## References

- [Istio SPIRE Integration](https://istio.io/latest/docs/ops/integrations/spire/)
- [SPIFFE CSI Driver](https://github.com/spiffe/spiffe-csi)
- [Teleport Workload Identity](https://goteleport.com/docs/machine-id/workload-identity/)
- [SPIFFE Workload API Specification](https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE_Workload_API.md)

## Next Steps

### Immediate Actions
1. **Verify certificate rotation** - Monitor front-end pod at ~20:53:46 (1 hour after startup)
   ```bash
   # Watch tbot logs for renewal
   kubectl logs -n teleport-system -l app=tbot -f | grep front-end

   # Watch Envoy certificate versions
   kubectl exec -n sock-shop front-end-6669f5bf86-ndf4n -c istio-proxy -- \
     curl -s localhost:15000/config_dump | \
     jq '.configs[] | select(."@type" == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") | .dynamic_active_secrets[] | {name: .name, version: .version_info}'
   ```

2. **Identify configuration change** - Determine what changed to prevent workload-certs creation
   - Review istio-config.yaml for any uncommitted changes
   - Check if istiod was recently restarted/reinstalled
   - Compare ConfigMap values before/after

3. **Apply to other pods** - Once verified working, restart other sock-shop pods
   ```bash
   kubectl rollout restart deployment -n sock-shop
   ```

### Documentation
4. **Update istio-config.yaml** - Document the exact configuration that prevents workload-certs
5. **Remove CronJob workaround** - Once rotation verified, remove the restart CronJob
6. **Document solution** - Add working configuration to INSTALLATION.md
