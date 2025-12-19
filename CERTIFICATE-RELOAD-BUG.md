# Certificate Reload Bug - Critical Issue

## Summary

Certificate rotation appears to be working (SDS secrets update) but Envoy does NOT reload certificates into TLS contexts, causing all mTLS connections to fail after certificate expiry.

## Timeline of Discovery

**2025-12-18 Morning**: User reports no connectivity

### Investigation Results:

**14:27 UTC**: Checked current status
- All pods: 2/2 Running ✅
- No recent errors in logs ✅

**14:29 UTC**: Tested connectivity
- Inter-service calls: **503 Service Unavailable** ❌
- Front-end itself: Working ✅

**14:29 UTC**: Checked certificates via TLS handshake
```
Certificate chain from openssl s_client:
notAfter=Dec 18 04:10:05 2025 GMT  ← EXPIRED 10 hours ago!
```

**14:29 UTC**: Checked Envoy's certificate endpoint
```bash
kubectl exec catalogue -c istio-proxy -- curl -s localhost:15000/certs
# ALL 45 certificates showed:
#   valid_from: 2025-12-18T03:09:05Z
#   expiration_time: 2025-12-18T04:10:05Z  ← EXPIRED
```

**Earlier at 14:10 UTC**: Checked Envoy config_dump
```json
{
  "name": "default",
  "version": "2025-12-18T14:10:56.265778036Z",
  "last_updated": "2025-12-18T14:10:56.267Z"
}
```

## The Bug

**Contradiction:**
- `/config_dump` → Secrets updated at **14:10:56 UTC** ✅
- `/certs` → Certificates expired at **04:10:05 UTC** ❌

**What this means:**
1. SDS secrets are being updated (visible in config_dump)
2. Envoy's TLS contexts are NOT reloading the new certificates
3. Expired certificates remain in use for all mTLS connections
4. All inter-service communication fails with 503 errors

## Temporary Workaround

**Applied**: Restarted all deployments
```bash
kubectl rollout restart deployment -n sock-shop
```

**Result**: Connectivity restored ✅
- New certificates issued: 14:30:03 - 15:31:03 UTC
- All services communicating again

## Certificate Issuance History

Checked tbot logs for last 12 hours:
```
Only 2 issuances per pod:
- Initial certificate on startup
- Second certificate (likely ROOTCA) on startup
```

**Expected for working rotation**: Multiple issuances every ~50 minutes (before 1h expiry)
**Actual**: Only startup issuances, no renewals

## Pod Timeline Analysis

**Old pod (front-end-5476b565c9-6pbqr)**:
- Created: 03:10:41 UTC
- Initial certs: 03:09 - 04:10 UTC (1h TTL)
- Cert expired: 04:10 UTC
- Pod ran with expired certs: **10+ hours**
- Finally restarted: 14:30 UTC

**This confirms**: Certificate rotation is NOT working

## Istio Agent Behavior

From startup logs:
```
Existing workload SDS socket found at var/run/secrets/workload-spiffe-uds/socket
Default Istio SDS Server will only serve files
Workload is using file mounted certificates
Skipping connecting to CA
Starting SDS grpc server
SDS grpc server for workload proxies failed to set up UDS
```

**What's happening:**
1. Istio agent detects external socket (tbot) → `ServeOnlyFiles = true`
2. Istio agent does NOT create CA client (correct - we don't want istiod)
3. Istio agent tries to start its own SDS server → **fails** (can't create socket)
4. Envoy connects directly to tbot socket

## Hypotheses

### Hypothesis 1: Envoy Not Subscribing to SDS Updates
**Theory**: When `ServeOnlyFiles=true`, Envoy fetches certificates once but doesn't maintain streaming connection

**Evidence**:
- config_dump shows secrets with updated timestamps
- But /certs shows old expired certificates
- No renewal requests in tbot logs

**Test**: Monitor Envoy's active gRPC streams to tbot socket

### Hypothesis 2: SDS Stream Disconnected
**Theory**: Initial SDS stream established but gets disconnected and never reconnects

**Evidence**:
- Initial certificates fetched successfully
- No subsequent fetches after expiry
- No reconnection attempts logged

**Test**: Check netstat for active connections to workload-spiffe-uds socket

### Hypothesis 3: TLS Context Not Configured for Hot Reload
**Theory**: Envoy's TLS contexts are configured to use static secrets, not dynamic SDS

**Evidence**:
- config_dump shows dynamic_active_secrets
- But TLS contexts might be configured differently
- Certificate reload requires explicit configuration

**Test**: Examine Envoy bootstrap configuration for TLS context SDS config

### Hypothesis 4: Known Limitation of ServeOnlyFiles Mode
**Theory**: When Istio sets `ServeOnlyFiles=true`, it doesn't properly integrate with external SDS providers

**Evidence**:
- Misleading log message: "using file mounted certificates"
- Istio agent doesn't manage the external socket connection
- No mechanism to push updates from external SDS to Envoy

**Test**: Review Istio source code for ServeOnlyFiles implementation

## Required Investigation

1. **Check Envoy's gRPC connections**:
   ```bash
   # From within istio-proxy container
   netstat -an | grep workload-spiffe-uds
   # Should show active STREAM connections
   ```

2. **Examine Envoy bootstrap config**:
   ```bash
   kubectl exec pod -c istio-proxy -- cat /etc/istio/proxy/envoy-rev.json
   # Look for SDS cluster configuration
   ```

3. **Monitor SDS stream activity**:
   ```bash
   # Enable debug logging
   istioctl pc log pod --level=sds:debug
   # Watch for DiscoveryRequest/DiscoveryResponse
   ```

4. **Check tbot connection tracking**:
   ```bash
   # From tbot pod
   ss -x | grep agent-sockets
   # Should show multiple CONNECTED streams (one per Envoy)
   ```

5. **Review Istio agent source code**:
   - `pkg/istio-agent/agent.go` - ServeOnlyFiles logic
   - How does external socket integration work?
   - Does it support streaming updates?

## Impact

**Severity**: CRITICAL

**Current state:**
- Certificate rotation: **BROKEN** ❌
- Pods must be manually restarted every ~50 minutes
- Overnight failures guaranteed
- Service mesh mTLS completely broken after 1 hour

**Workaround viability**:
- ❌ Manual restarts: Not sustainable
- ❌ CronJob restarts: Band-aid, not a solution
- ✅ Fix root cause: Required

## Questions

1. Is `ServeOnlyFiles` mode meant to support streaming SDS updates?
2. Does Envoy maintain persistent connection to external SPIFFE socket?
3. How do official Istio + SPIRE integrations handle this?
4. Is there an Envoy configuration flag we're missing?
5. Should we be using a different integration approach?

## Next Steps

1. Enable debug logging on Envoy SDS
2. Monitor gRPC stream connections
3. Review Istio + SPIRE reference implementations
4. Consider alternative approaches:
   - Use files written by tbot (no rotation)
   - Use Istio's built-in SPIRE integration (different architecture)
   - Custom Envoy SDS provider (complex)

## References

- Istio agent source: `pkg/istio-agent/agent.go`
- SPIFFE Workload API spec: https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE_Workload_API.md
- Envoy SDS documentation: https://www.envoyproxy.io/docs/envoy/latest/configuration/security/secret
- Istio + SPIRE integration: https://istio.io/latest/docs/ops/integrations/spire/
