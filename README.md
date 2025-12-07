# Istio + Teleport Workload Identity Integration

This project demonstrates the integration of Teleport's Workload Identity service with Istio service mesh, enabling SPIFFE-compliant workload identities for Kubernetes applications.

## Overview

This integration provides:

- **Teleport-issued SPIFFE identities**: Workloads receive cryptographic identities from Teleport instead of Istio's built-in CA
- **Centralized identity management**: Manage workload identities across multiple clusters from a single Teleport instance
- **SPIFFE Workload API compliance**: Standard SPIFFE implementation via Unix domain socket
- **Istio mesh integration**: Seamless integration with Istio's service mesh capabilities

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                 Teleport Cluster                     │
│  - Workload Identity Issuer                         │
│  - Bot Authentication (Kubernetes Join)              │
└─────────────────────────────────────────────────────┘
                         ▲
                         │ gRPC
                         │
┌─────────────────────────────────────────────────────┐
│              Kubernetes Cluster                      │
│                                                       │
│  ┌─────────────────────────────────────────┐       │
│  │    tbot DaemonSet (per node)            │       │
│  │  - Workload Identity API Server          │       │
│  │  - SPIFFE Socket: /run/spire/sockets/   │       │
│  └─────────────────────────────────────────┘       │
│                         │                            │
│                         │ Unix Socket                │
│                         ▼                            │
│  ┌─────────────────────────────────────────┐       │
│  │          Application Pod                 │       │
│  │  ┌──────────┐  ┌──────────────────┐    │       │
│  │  │   App    │  │   Istio Proxy    │    │       │
│  │  │          │  │  (reads SPIFFE   │    │       │
│  │  │          │  │   identities)    │    │       │
│  │  └──────────┘  └──────────────────┘    │       │
│  └─────────────────────────────────────────┘       │
│                                                       │
│  ┌─────────────────────────────────────────┐       │
│  │         Istio Control Plane              │       │
│  │  - istiod (with SPIFFE integration)      │       │
│  │  - Trust Domain: ellinj.teleport.sh      │       │
│  └─────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────┘
```

## Components

### Istio Configuration
- **Trust Domain**: `cluster.local`
- **Path Normalization**: Disabled (NONE) for SPIFFE compatibility
- **Certificate Provider**: External (Teleport via SPIFFE Workload API)

### Teleport Components
- **Bot Role**: `istio-workload-identity-issuer` - Allows issuing workload identities with `env:dev` label
- **Workload Identity**: `istio-workloads` - Defines SPIFFE ID template for Kubernetes workloads
- **Join Method**: Kubernetes with static JWKS validation

### Kubernetes Resources
- **Namespace**: `teleport-system` - Contains tbot DaemonSet
- **tbot DaemonSet**: Runs on each node, provides Workload Identity API via Unix socket
- **SPIFFE Socket**: `/run/spire/sockets/socket` - Standard SPIFFE Workload API endpoint

## SPIFFE ID Format

Workloads receive SPIFFE IDs following the Istio-compatible pattern:

```
spiffe://ellinj.teleport.sh/ns/<namespace>/sa/<service-account>
```

Example:
```
spiffe://ellinj.teleport.sh/ns/test-app/sa/test-app
```

## Prerequisites

- Kubernetes cluster (1.27+)
- `kubectl` configured with cluster access
- `istioctl` (1.28+)
- Active Teleport cluster with admin access
- `tctl` and `tsh` configured

## Quick Start

See [INSTALLATION.md](INSTALLATION.md) for detailed installation instructions.

```bash
# 1. Install Istio with SPIFFE configuration
./istio-install.sh

# 2. Create cluster-specific join token from template
./create-token.sh  # Automated helper script
# Or manually create from template (see INSTALLATION.md for details)

# 3. Create Teleport resources
tctl create -f teleport-bot-role.yaml
tctl create -f teleport-workload-identity.yaml
tctl create -f istio-tbot-token.yaml

# 4. Deploy tbot
kubectl apply -f tbot-rbac.yaml
kubectl apply -f tbot-config.yaml
kubectl apply -f tbot-daemonset.yaml

# 5. Deploy test application
kubectl apply -f test-app-deployment.yaml
```

## Verification

Check that all components are running:

```bash
# Istio components
kubectl get pods -n istio-system

# tbot DaemonSet
kubectl get pods -n teleport-system

# Test application
kubectl get pods -n test-app

# Verify SPIFFE socket
kubectl exec -n test-app <pod-name> -c istio-proxy -- ls -la /var/run/secrets/workload-spiffe-uds/
```

## Sock Shop Demo Application

**What Works**:
- ✅ Teleport issues SPIFFE certificates correctly
- ✅ Pods receive certificates with proper SPIFFE IDs
- ✅ Trust domain configuration matches
- ✅ External access to services works
- ✅ Service-to-service mTLS validation succeeds with Teleport-issued certificates

For a comprehensive demonstration attempt:

```bash
# Deploy the Sock Shop demo
kubectl apply -f sock-shop-demo.yaml

# Wait for all pods to be ready
kubectl get pods -n sock-shop -w

# Test baseline functionality
FRONTEND_IP=$(kubectl get svc -n sock-shop front-end -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://$FRONTEND_IP/  # External access works
curl http://$FRONTEND_IP/catalogue  # Backend service fails with cert error
```

See [SOCK-SHOP-DEMO.md](SOCK-SHOP-DEMO.md) for detailed setup steps and investigation notes embedded there.

## Files

### Configuration Files (Safe to Commit)
- `istio-install.sh` - Automated Istio installation script
- `istio-config.yaml` - Istio configuration with SPIFFE integration
- `create-token.sh` - Helper script to create cluster-specific join token
- `cleanup.sh` - Comprehensive cleanup script for all resources
- `teleport-bot-role.yaml` - Teleport role for workload identity issuer
- `teleport-workload-identity.yaml` - Workload identity definition
- `istio-tbot-token.yaml.template` - Template for Kubernetes join token (copy and customize)
- `tbot-rbac.yaml` - Kubernetes RBAC for tbot
- `tbot-config.yaml` - tbot configuration
- `tbot-daemonset.yaml` - tbot DaemonSet deployment
- `test-app-deployment.yaml` - Sample application with Istio injection
- `sock-shop-demo.yaml` - Sock Shop microservices demo application
- `sock-shop-deny-all.yaml` - Default deny-all policy for zero-trust demonstration
- `sock-shop-policies.yaml` - Complete Istio authorization policies using SPIFFE IDs

### Generated Files (Gitignored - DO NOT COMMIT)
- `istio-tbot-token.yaml` - Cluster-specific join token with JWKS (generated from template)

**Security Note**: The `istio-tbot-token.yaml` file contains sensitive cluster-specific JWKS and should never be committed to version control. It is automatically excluded via `.gitignore`.

## Key Configuration Notes

### SPIFFE Socket Path
The configuration uses `/run/spire/sockets/socket` as the socket path, which matches the standard SPIFFE Workload API location. This eliminates the need for symlinks or custom path configurations.

### Trust Domain
Must match between Istio (`ellinj.teleport.sh`) and the workload's SPIFFE ID prefix.

### Path Normalization
Set to `NONE` in Istio configuration to maintain SPIFFE ID compatibility.

### No Trailing Slash
SPIFFE IDs must NOT have trailing slashes per the SPIFFE specification.

## Troubleshooting

### tbot pods failing with JWT validation error
This typically means the Kubernetes join token has incorrect or outdated JWKS. Extract the current cluster's JWKS and update the token:

```bash
kubectl get --raw /openid/v1/jwks
# Update istio-tbot-token.yaml with new JWKS
tctl create -f istio-tbot-token.yaml --force
kubectl delete pods -n teleport-system -l app=tbot
```

### Istio proxy not detecting SPIFFE socket
Check tbot logs and ensure the DaemonSet is running on the same node as your application pod:

```bash
kubectl logs -n teleport-system <tbot-pod-name>
```

### Certificate errors in Istio proxy
Verify trust domain configuration matches between Istio and Teleport workload identity.

## Cleanup

To completely remove all installed components:

```bash
./cleanup.sh
```

The cleanup script removes:
- Istio components (istio-system namespace)
- tbot DaemonSet and resources (teleport-system namespace)
- Test application (test-app namespace)
- Teleport server-side resources (role, workload identity, token via tctl)
- Local generated token files (optional, with confirmation)

The cleanup script is self-contained; see its inline help for options.

## Resources

- [Teleport Workload Identity Documentation](https://goteleport.com/docs/machine-id/workload-identity/)
- [Istio Certificate Management](https://istio.io/latest/docs/tasks/security/cert-management/)
- [SPIFFE Specification](https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE.md)

## License

This is a demonstration project for integrating Teleport Workload Identity with Istio.
