# Project Status: Istio + Teleport Workload Identity Integration

**Last Updated**: December 5, 2025
**Cluster**: ellinj.teleport.sh
**Status**: ⚠️ Partial Success - Further Investigation Required

## Quick Summary

This project demonstrates the integration of Teleport's Workload Identity service with Istio service mesh for SPIFFE-compliant workload identities in Kubernetes.

### Current Status

**Working** ✅:
- Teleport issues SPIFFE certificates to Kubernetes workloads
- tbot DaemonSet provides Workload Identity API on all nodes
- Istio sidecars detect and load Teleport-issued certificates
- SPIFFE IDs correctly formatted: `spiffe://ellinj.teleport.sh/k8s/<namespace>/<sa>`
- Trust domain properly configured
- Pod attestation via Kubernetes API working

**Not Working** ❌:
- Service-to-service mTLS validation fails
- Error: `CERTIFICATE_VERIFY_FAILED` in Envoy
- Authorization policies cannot be fully tested due to mTLS failure

## Project Files

### Core Configuration
- `istio-config.yaml` - Istio with SPIFFE integration and trust domain `ellinj.teleport.sh`
- `istio-install.sh` - Automated Istio installation script
- `tbot-config.yaml` - tbot Workload Identity API configuration
- `tbot-daemonset.yaml` - tbot DaemonSet for all nodes
- `tbot-rbac.yaml` - Kubernetes RBAC for tbot

### Teleport Resources
- `teleport-bot-role.yaml` - Teleport role for workload identity issuer
- `teleport-workload-identity.yaml` - Workload identity definition
- `istio-tbot-token.yaml.template` - Template for Kubernetes join token
- `create-token.sh` - Helper script to generate cluster-specific token

### Demo Applications
- `test-app-deployment.yaml` - Simple test application (works)
- `sock-shop-demo.yaml` - Microservices demo with Istio annotations
- `sock-shop-deny-all.yaml` - Default deny policy for zero-trust demo
- `sock-shop-policies.yaml` - SPIFFE-based authorization policies
- `sock-shop-permissive-mtls.yaml` - Permissive mTLS mode

### Documentation
- `README.md` - Project overview and quick start
- `INSTALLATION.md` - Step-by-step installation guide
- `SOCK-SHOP-DEMO.md` - Sock Shop demo walkthrough
- `TROUBLESHOOTING-MTLS.md` - Detailed mTLS investigation notes (⭐ START HERE)
- `SECURITY.md` - Security guidelines for token management
- `CLEANUP-IMPROVEMENTS.md` - Cleanup script documentation
- `CHANGELOG-SECURITY.md` - Security improvements changelog

### Utility Scripts
- `cleanup.sh` - Comprehensive cleanup script
- `.gitignore` - Protects sensitive token files

## What You Can Demonstrate

### 1. SPIFFE Certificate Issuance ✅
```bash
kubectl exec -n test-app <pod> -c istio-proxy -- \
  curl -s localhost:15000/certs | jq '.certificates[0].cert_chain[0].subject_alt_names'
```

Shows SPIFFE ID: `spiffe://ellinj.teleport.sh/k8s/test-app/test-app`

### 2. SPIFFE Socket Detection ✅
```bash
kubectl exec -n test-app <pod> -c istio-proxy -- \
  ls -la /var/run/secrets/workload-spiffe-uds/socket
```

Shows tbot's Workload API socket is accessible.

### 3. Workload Identity Lifecycle ✅
```bash
kubectl logs -n test-app <pod> -c istio-proxy | grep -i "spiffe\|workload"
```

Shows Istio proxy detecting and using Teleport's SPIFFE socket.

### 4. Teleport Audit Logs ✅
```bash
tctl events list --type=workload_identity.issue --count=20
```

Shows Teleport issuing workload identities to pods.

## Known Issues

### Primary Issue: mTLS Certificate Validation

**Error**: `CERTIFICATE_VERIFY_FAILED`

**Details**: See [TROUBLESHOOTING-MTLS.md](TROUBLESHOOTING-MTLS.md)

**Impact**:
- Cannot demonstrate full service mesh mTLS
- Cannot test authorization policies end-to-end
- Cannot show zero-trust security model in action

**Possible Causes**:
1. Certificate extension incompatibility
2. Certificate chain format differences
3. Trust bundle distribution issue
4. SPIFFE Workload API implementation differences

**Next Steps**:
1. Contact Teleport support with troubleshooting doc
2. Compare certificate format with SPIRE
3. Test with different Istio/Envoy versions
4. Enable detailed Envoy TLS debugging

## Quick Start (Investigation Mode)

```bash
# 1. Install Istio
./istio-install.sh

# 2. Create cluster-specific token
./create-token.sh
tctl create -f istio-tbot-token.yaml

# 3. Deploy Teleport resources
tctl create -f teleport-bot-role.yaml
tctl create -f teleport-workload-identity.yaml

# 4. Deploy tbot
kubectl apply -f tbot-rbac.yaml
kubectl apply -f tbot-config.yaml
kubectl apply -f tbot-daemonset.yaml

# 5. Verify tbot is working
kubectl get pods -n teleport-system
kubectl logs -n teleport-system <tbot-pod>

# 6. Deploy test application
kubectl apply -f test-app-deployment.yaml

# 7. Verify SPIFFE integration
kubectl exec -n test-app <pod> -c istio-proxy -- \
  curl -s localhost:15000/certs | jq

# 8. Attempt sock-shop demo (will show mTLS issue)
kubectl apply -f sock-shop-demo.yaml
kubectl get pods -n sock-shop -w

# 9. Test (will fail with certificate error)
FRONTEND_IP=$(kubectl get svc -n sock-shop front-end -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://$FRONTEND_IP/catalogue
```

## Configuration Details

### Trust Domain
- **Teleport**: `ellinj.teleport.sh`
- **Istio**: `ellinj.teleport.sh` (updated to match)
- **SPIFFE IDs**: `spiffe://ellinj.teleport.sh/k8s/<namespace>/<service-account>`

### Istio Version
- **Version**: 1.28.0
- **Profile**: default
- **Custom Template**: "spire" for SPIFFE socket integration

### Teleport Version
- **tbot**: 18.5.0
- **Proxy**: ellinj.teleport.sh:443

### Annotations Required
All pods using Teleport certificates must have:
```yaml
annotations:
  inject.istio.io/templates: "sidecar,spire"
```

## Cleanup

```bash
./cleanup.sh
```

Removes:
- Istio (istio-system namespace)
- tbot (teleport-system namespace)
- Test apps (test-app, sock-shop namespaces)
- Teleport resources (role, workload identity, token)
- Local token files (optional)

## Support and Next Steps

### For Investigation
1. Read [TROUBLESHOOTING-MTLS.md](TROUBLESHOOTING-MTLS.md) - Complete investigation notes
2. Check Envoy logs: `kubectl logs -n sock-shop <pod> -c istio-proxy`
3. Inspect certificates: `kubectl exec -n sock-shop <pod> -c istio-proxy -- curl -s localhost:15000/certs`

### For Teleport Support
Include:
- [TROUBLESHOOTING-MTLS.md](TROUBLESHOOTING-MTLS.md)
- Certificate details from Envoy
- Istio version (1.28.0)
- Teleport version (18.5.0)
- Error message: `CERTIFICATE_VERIFY_FAILED`

### Alternative Approaches
1. **Test with SPIRE**: Use SPIRE instead of Teleport as control test
2. **Different Istio Version**: Try older/newer Istio versions
3. **Custom Envoy Config**: Investigate Envoy TLS validation settings
4. **Certificate Inspection**: Deep dive into X.509 extensions

## Success Criteria

### What's Working (Can Demo)
- ✅ tbot DaemonSet deployment
- ✅ Workload Identity API availability
- ✅ SPIFFE certificate issuance
- ✅ Istio sidecar integration
- ✅ Pod attestation
- ✅ Certificate lifecycle management

### What's Blocked (Cannot Demo)
- ❌ Service-to-service mTLS
- ❌ Authorization policies
- ❌ Zero-trust networking
- ❌ Identity-based access control

## Project Value

Despite the mTLS issue, this project demonstrates:

1. **Integration Architecture**: How to integrate external identity providers with Istio
2. **SPIFFE Compliance**: Proper SPIFFE ID format and Workload API usage
3. **Kubernetes Attestation**: Pod identity verification via Kubernetes API
4. **Configuration Patterns**: Istio custom templates and annotations
5. **Troubleshooting Methodology**: Systematic debugging approach

The documentation and configuration can serve as a foundation for:
- Working with Teleport support to resolve the issue
- Testing with future Teleport/Istio versions
- Comparing with SPIRE implementation
- Understanding certificate validation in service mesh

## Contact

For issues with this project:
- Review [TROUBLESHOOTING-MTLS.md](TROUBLESHOOTING-MTLS.md)
- Check Teleport documentation: https://goteleport.com/docs/
- Check Istio documentation: https://istio.io/latest/docs/

For the mTLS certificate validation issue:
- Contact Teleport support with troubleshooting documentation
- Include certificate samples and error messages
- Reference SPIFFE Workload API compatibility
