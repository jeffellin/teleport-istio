# Duplicate SPIFFE SVID Issuance Explanation

## Observation

Each Istio workload receives two SPIFFE SVID issuance events in Teleport, appearing as duplicates in the audit log within milliseconds of each other:

```
2025-12-14T08:53:19.346Z - SPIFFE SVID Issued [spiffe://ellinj.teleport.sh/ns/sock-shop/sa/catalogue-db]
2025-12-14T08:53:19.262Z - SPIFFE SVID Issued [spiffe://ellinj.teleport.sh/ns/sock-shop/sa/catalogue-db]
```

## Root Cause

This is **expected behavior** caused by how Envoy's TLS configuration works. Envoy separates certificate material into two distinct SDS (Secret Discovery Service) secrets:

1. **"default"** - The workload's identity certificate (for presenting to peers)
2. **"ROOTCA"** - The trust bundle/validation context (for verifying peers)

## Technical Details

### tbot Logs

Both requests come from the same Envoy process and result in separate SVID issuances:

```
08:53:19.353Z - Issued Workload Identity Credential
  pid: 13122
  spiffe_id: spiffe://ellinj.teleport.sh/ns/sock-shop/sa/catalogue-db
  credential.type: x509-svid
  serial_number: f3:8b:b9:90:81:10:06:21:d9:2f:db:ac:88:41:ea:ad

08:53:19.394Z - Issued Workload Identity Credential
  pid: 13122  (same process)
  spiffe_id: spiffe://ellinj.teleport.sh/ns/sock-shop/sa/catalogue-db
  credential.type: x509-svid
  serial_number: 27:5d:83:20:f6:d0:43:77:eb:f7:ad:92:45:55:dd:ff (different cert)
```

### Envoy Logs

Envoy detects the SPIFFE Workload API socket and requests both secrets:

```
08:53:10.770629Z - Existing workload SDS socket found at var/run/secrets/workload-spiffe-uds/socket
08:53:10.770923Z - Starting default Istio SDS Server
08:53:10.771073Z - Workload is using file mounted certificates
```

### Envoy Config Dump

Shows two separate dynamic secrets:

```json
{
  "name": "default",
  "version": "2025-12-14T08:53:19.394986386Z",
  "secret": {
    "tls_certificate": {
      "certificate_chain": {...},
      "private_key": {...}
    }
  }
},
{
  "name": "ROOTCA",
  "version": "2025-12-14T08:53:19.353998144Z",
  "secret": {
    "validation_context": {
      "custom_validator_config": {
        "name": "envoy.tls.cert_validator.spiffe",
        "trust_domains": [...]
      }
    }
  }
}
```

## Istio Source Code

### Constant Definitions

**File**: `pkg/security/security.go`

```go
// WorkloadKeyCertResourceName is the resource name of the discovery request for workload identity.
const WorkloadKeyCertResourceName = "default"

// RootCertReqResourceName is resource name of discovery request for root certificate.
const RootCertReqResourceName = "ROOTCA"
```

### Implementation Rationale

**File**: `security/pkg/nodeagent/cache/secretcache.go`

Key comment from the code:

> "The primary usage is to fetch the two specially named resources: `default`, which refers to the workload's spiffe certificate, and ROOTCA, which contains just the root certificate for the workload certificates. **These are separated only due to the fact that Envoy has them separated.**"

### Envoy Bootstrap Template

**File**: `tools/packaging/common/envoy_bootstrap_v2.json`

The bootstrap configuration defines two separate SDS secret configurations:

1. `tls_certificate_sds_secret_configs` → name: `"default"`
2. `validation_context_sds_secret_config` → name: `"ROOTCA"`

Both point to the same SDS socket endpoint but request different secret names.

## Why This Happens

### SPIFFE Workload API Behavior

According to the SPIFFE specification, every `FetchX509SVID` response includes:
- The X.509-SVID (identity certificate)
- Trust bundles (CA certificates for all trust domains)

### Istio's Approach

Istio makes **two separate calls** to `FetchX509SVID`:
1. First call → extracts trust bundle → used for "ROOTCA"
2. Second call → extracts SVID → used for "default"

Each call to the SPIFFE Workload API generates:
- A new X.509-SVID with unique serial number
- The same trust bundle (identical CA certificates)
- A separate audit event in Teleport

### More Efficient Alternative

The SPIFFE Workload API provides `FetchX509Bundles` specifically for getting trust bundles without issuing new SVIDs. However, Istio's current implementation doesn't use this optimization.

## Impact

### This is Normal
- ✅ Expected behavior from Envoy's TLS architecture
- ✅ Integration is working correctly
- ✅ mTLS is functioning properly
- ✅ No security impact

### Minor Inefficiencies
- Each workload generates 2x audit events (cosmetic)
- Each workload issues 2 certificates instead of 1 (one is unused)
- Slight increase in CPU/memory for extra certificate generation

### Trust Bundles Are Identical

All workloads in the same trust domain receive identical trust bundles. The first SVID issued contains the trust bundle that Envoy extracts for validation, while the second SVID is what Envoy actually uses for its identity.

## Verification

You can verify this behavior by checking:

```bash
# Get pod name
POD=$(kubectl get pod -n sock-shop -l app=catalogue-db -o jsonpath='{.items[0].metadata.name}')

# View Envoy's dynamic secrets
kubectl exec -n sock-shop $POD -c istio-proxy -- \
  curl -s localhost:15000/config_dump | \
  jq '.configs[] | select(."@type" == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") | .dynamic_active_secrets[] | {name: .name, version: .version_info}'

# Expected output: Two secrets with different timestamps
# - "default": The SVID certificate (newer timestamp)
# - "ROOTCA": The trust bundle (older timestamp)
```

## References

- [Istio security.go - Constant definitions](https://github.com/istio/istio/blob/master/pkg/security/security.go)
- [Istio secretcache.go - Implementation explanation](https://github.com/istio/istio/blob/master/security/pkg/nodeagent/cache/secretcache.go)
- [Istio sdsservice.go - SDS service implementation](https://github.com/istio/istio/blob/master/security/pkg/nodeagent/sds/sdsservice.go)
- [SPIFFE Workload API Specification](https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE_Workload_API.md)
- [Istio Issue #41414 - Customisation of SDS secret names](https://github.com/istio/istio/issues/41414)

## Conclusion

The duplicate SPIFFE SVID issuance is a consequence of Envoy's architectural separation of identity certificates and validation contexts. While this results in additional audit events and certificate generation, it's expected behavior and does not indicate a problem with the integration. The system is functioning as designed.
