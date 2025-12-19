# Root Cause Analysis: Certificate Rotation Failure

## Executive Summary

**Issue**: Certificates expire after 1 hour and are not rotated, causing complete service mesh failure.

**Root Cause**: SPIFFE Workload API streaming connection between Envoy and tbot is never established or maintained, preventing automatic certificate renewal.

**Evidence**: No certificate issuances by tbot between initial pod startup and manual restart (10+ hour gap).

## Key Findings

### 1. tbot Is NOT Issuing Renewal Certificates

**Evidence from tbot logs (last 12 hours):**
```bash
# Certificate issuance timestamps:
2025-12-18T14:31:02.566Z - Initial certificates (after restart)
2025-12-18T14:31:02.574Z - Initial certificates (after restart)
... (only startup issuances at 14:31 UTC)

# MISSING: No issuances between 04:10 UTC (first expiry) and 14:31 UTC (restart)
```

**What this means:**
- tbot only issues certificates when Envoy first connects
- No renewals are being requested via SPIFFE Workload API
- The streaming gRPC connection is either:
  - Never established
  - Established but disconnected early
  - Established but not sending renewal requests

### 2. Istio Agent Behavior

**From pod logs:**
```
Existing workload SDS socket found at var/run/secrets/workload-spiffe-uds/socket
Default Istio SDS Server will only serve files
Workload is using file mounted certificates
Skipping connecting to CA
```

**Source code confirms (based on user input):**
- `initSdsServer` unconditionally registers `OnSecretUpdate` callback
- When workload secret changes, callback fires and Envoy is notified
- This is automatic - no configuration needed

**Key insight:** The Istio agent IS configured correctly to push updates to Envoy.

### 3. The Missing Link

**Question:** If Istio agent pushes updates when secrets change, why don't secrets change?

**Answer:** Because tbot never issues new certificates!

**The SPIFFE Workload API Flow:**
```
1. Envoy connects to tbot socket → FetchX509SVID (initial)
2. tbot issues 1-hour certificate
3. Envoy maintains streaming gRPC connection
4. At ~50 minutes, Envoy requests renewal via streaming API
5. tbot issues new certificate
6. Istio agent's OnSecretUpdate callback fires
7. Envoy reloads certificates

ACTUAL BEHAVIOR:
1. ✅ Envoy connects to tbot socket
2. ✅ tbot issues 1-hour certificate
3. ❌ Streaming connection is NOT maintained
4. ❌ No renewal requests
5. ❌ No new certificates issued
6. ❌ OnSecretUpdate never fires (nothing changed)
7. ❌ Certificates expire
```

## Architecture Issue

### Current Understanding

When `ServeOnlyFiles = true` (socket exists):
- Istio agent does NOT create its own SDS server
- Envoy is supposed to connect DIRECTLY to the external socket (tbot)
- tbot is responsible for maintaining the streaming connection
- tbot's SPIFFE Workload API should handle rotation

**The Problem:**
Based on the evidence (no tbot renewal issuances), **Envoy is not maintaining a streaming connection to tbot's SPIFFE Workload API socket**.

### Possible Causes

#### Hypothesis A: Envoy Not Configured for Streaming
**Theory:** Envoy's SDS configuration fetches certificates once but doesn't maintain streaming subscription

**Evidence:**
- config_dump shows `dynamic_active_secrets` (suggests SDS)
- But secrets only update at pod startup
- No evidence of ongoing stream activity

**Need to verify:**
- Envoy bootstrap configuration
- SDS cluster definition
- StreamAggregatedResources vs simple fetch

#### Hypothesis B: tbot Socket Not Implementing Streaming API
**Theory:** tbot's socket accepts connections and serves certificates but doesn't maintain streaming connections

**Evidence:**
- tbot logs show only initial issuances
- No "client disconnected" or "stream closed" messages
- No renewal requests logged

**Need to verify:**
- tbot Workload API implementation
- Does it support streaming FetchX509SVIDResponse?
- Connection lifecycle management

#### Hypothesis C: Envoy Bootstrap Misconfiguration
**Theory:** Envoy is configured to use static certificates from socket, not streaming SDS

**Evidence:**
- Agent logs: "Workload is using file mounted certificates"
- This message is misleading (confirmed by user)
- But maybe Envoy's actual configuration is file-based?

**Need to verify:**
- Envoy bootstrap JSON
- TLS context configuration
- SDS cluster vs file-based certs

## What Works vs What Doesn't

### ✅ Working Components

1. **tbot DaemonSet**: Running, socket created at `/run/spire/agent-sockets/socket`
2. **SPIFFE CSI Driver**: Mounting socket into pods correctly
3. **CSI Volume**: Present in pods, socket accessible
4. **Initial Certificate Issuance**: Envoy gets first certificate successfully
5. **Istio Agent SDS**: OnSecretUpdate mechanism functional
6. **Inter-service mTLS**: Works with fresh certificates

### ❌ Not Working

1. **Certificate Renewal**: No renewals requested after initial issuance
2. **Streaming Connection**: No evidence of maintained gRPC stream
3. **Rotation Scheduler**: SecretManager rotation timer not firing (because secrets don't change)
4. **Long-running Pods**: Fail after 1 hour

## Timeline Analysis

### Old Pod (front-end-5476b565c9-6pbqr)

```
03:09 UTC - tbot issues certificate (valid 03:09 - 04:10)
03:10 UTC - Pod starts
03:10 UTC - Envoy fetches certificate from tbot
04:10 UTC - Certificate expires
04:10 - 14:30 UTC - NO NEW CERTIFICATES ISSUED (10+ hour gap)
14:27 UTC - Connectivity fails (503 errors)
14:30 UTC - Manual restart (connectivity restored)
```

### Certificates During Gap

**config_dump showed:**
- Secrets with version "2025-12-18T14:10:56..."
- `last_updated: "2025-12-18T14:10:56.267Z"`

**BUT /certs endpoint showed:**
- All certificates expired at 04:10:05 UTC

**Interpretation:**
- SDS secrets metadata was updating (timestamp changes)
- But secret content (certificate) was the same expired cert
- Suggests Istio agent was re-pushing the cached secret
- But no new certificate was ever issued by tbot

## Required Investigation

To definitively identify the root cause:

### 1. Examine Envoy Bootstrap Configuration

```bash
kubectl exec pod -c istio-proxy -- cat /etc/istio/proxy/envoy-rev.json | jq '.static_resources.clusters[] | select(.name | contains("sds"))'
```

**Look for:**
- SDS cluster definition
- gRPC streaming configuration
- Socket path configuration

### 2. Check tbot SPIFFE Workload API Implementation

```bash
kubectl logs -n teleport-system -l app=tbot | grep -E "stream|connection|client"
```

**Look for:**
- Client connection established/closed messages
- Streaming API calls
- FetchX509SVID vs FetchX509Bundles calls

### 3. Monitor Active Connections

From within pods:
```bash
# Check if Envoy has active connection to socket
lsof | grep workload-spiffe-uds

# From tbot pod
ss -x | grep agent-sockets
```

**Expected:** Active CONNECTED streams from each Envoy to tbot

### 4. Enable Debug Logging (Correctly)

**For istio-agent (sds, security scopes):**
```yaml
annotations:
  sidecar.istio.io/agentLogLevel: "default:info,sds:debug,security:debug"
```

**For Envoy (secret logger):**
```yaml
annotations:
  sidecar.istio.io/logLevel: "warning"
```

Then check logs for:
- `generated new workload certificate...ttl=...`
- `scheduled certificate for rotation in...`
- `added dynamic secret` (Envoy)
- `create secret` (Envoy)

### 5. Review Istio + SPIRE Reference Implementation

Compare with official Istio + SPIRE integration:
- Does it use ServeOnlyFiles mode?
- How is Envoy bootstrap configured?
- Are there special settings required?

## Temporary Workarounds

### Current: Manual Restarts
```bash
kubectl rollout restart deployment -n sock-shop
```

**Pros:** Restores connectivity immediately
**Cons:** Not sustainable, requires monitoring

### Option: CronJob Restarts
Restart pods every 50 minutes (before 1h expiry)

**Pros:** Automated
**Cons:** Pod churn, not a real solution

### Option: Longer Certificate TTL
Configure tbot to issue 24-hour certificates

**Pros:** Reduces frequency of failures
**Cons:** Larger security window, doesn't fix root cause

## Next Steps

1. ✅ Connectivity restored via manual restart
2. ⏳ Certificate rotation investigation ongoing
3. ⏳ Enable debug logging (need correct annotation syntax)
4. ⏳ Examine Envoy bootstrap configuration
5. ⏳ Monitor tbot connection lifecycle
6. ⏳ Compare with official Istio + SPIRE setup
7. ⏳ Consider alternative integration approaches

## Questions

1. Does tbot's SPIFFE Workload API socket support streaming?
2. Is Envoy configured to use streaming SDS or one-time fetch?
3. Why does ServeOnlyFiles mode work for initial cert but not rotation?
4. Are we missing a critical Envoy configuration flag?
5. Is there an incompatibility between tbot and Istio's expectations?

## Conclusion

**Certificate rotation is fundamentally broken** because the streaming SPIFFE Workload API connection is not being established or maintained. Envoy fetches initial certificates successfully but never requests renewals, and tbot never issues them. This results in certificates expiring after 1 hour with no automatic renewal.

**The fix requires** either:
- Configuring Envoy to maintain streaming connection to tbot socket
- Using a different integration approach (files, different SDS provider, etc.)
- Switching to official Istio + SPIRE architecture

**Current status:** Investigation ongoing, connectivity temporarily restored via manual restarts.
