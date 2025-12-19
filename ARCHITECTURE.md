# Istio + Teleport (tbot) + SPIFFE CSI Architecture

This document describes the architecture and configuration for using Teleport workload identity with Istio service mesh via tbot and the SPIFFE CSI driver.

## Architecture Overview

### Complete Data Flow: Istio Proxy ↔ tbot Communication

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Each Worker Node                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  ┌────────────────────────────────────────────────────────────┐         │
│  │ 1. tbot (DaemonSet Pod)                                    │         │
│  │    - Connects to: ellinj.teleport.sh:443                  │         │
│  │    - Provides: SPIFFE Workload API                        │         │
│  │    - Creates socket: /run/spire/agent-sockets/socket      │         │
│  │    - Volume: hostPath (shared across node)                │         │
│  └────────────────────┬───────────────────────────────────────┘         │
│                       │                                                   │
│                       ▼                                                   │
│  /run/spire/agent-sockets/socket  ◄──────────────────┐                 │
│  (hostPath - shared on node filesystem)               │                 │
│                       │                                │                 │
│                       │                                │                 │
│                       ▼                                │                 │
│  ┌────────────────────────────────────────────┐       │                 │
│  │ 2. SPIFFE CSI Driver (DaemonSet)           │       │                 │
│  │    - Reads: /run/spire/agent-sockets       │◄──────┘                 │
│  │    - Exposes as: CSI ephemeral volumes     │                         │
│  │    - Driver name: "csi.spiffe.io"          │                         │
│  │    - Per-pod mount verification            │                         │
│  └────────────────────┬───────────────────────┘                         │
│                       │                                                   │
│                       │ Creates per-pod mount at:                        │
│                       │ /var/lib/kubelet/pods/<pod-uid>/volumes/...     │
│                       ▼                                                   │
│  ┌────────────────────────────────────────────────────────┐             │
│  │ 3. Application Pod (e.g., front-end)                   │             │
│  │    ┌──────────────────────────────────────────────┐   │             │
│  │    │ istio-proxy container                         │   │             │
│  │    │                                               │   │             │
│  │    │  Volume spec:                                 │   │             │
│  │    │    - name: workload-socket                    │   │             │
│  │    │      csi:                                     │   │             │
│  │    │        driver: "csi.spiffe.io"                │   │             │
│  │    │                                               │   │             │
│  │    │  Mount: /run/secrets/workload-spiffe-uds     │   │             │
│  │    │                                               │   │             │
│  │    │  Environment:                                 │   │             │
│  │    │    CA_ADDR=unix:///.../socket                │   │             │
│  │    │    PILOT_CERT_PROVIDER=workloadapi           │   │             │
│  │    │                                               │   │             │
│  │    │  ┌─────────────────────────────────────┐    │   │             │
│  │    │  │ Envoy Proxy                          │    │   │             │
│  │    │  │  - Connects to socket                │    │   │             │
│  │    │  │  - Requests X.509-SVIDs from tbot    │    │   │             │
│  │    │  │  - Gets Teleport-issued certificates │    │   │             │
│  │    │  └─────────────────────────────────────┘    │   │             │
│  │    └──────────────────────────────────────────────┘   │             │
│  └────────────────────────────────────────────────────────┘             │
│                                                                           │
└─────────────────────────────────────────────────────────────────────────┘
```

## Key Configuration Files

### 1. tbot-daemonset.yaml

tbot creates the Workload API socket on a hostPath that is shared across the node:

```yaml
volumeMounts:
  - name: spiffe-socket
    mountPath: /run/spire/agent-sockets
volumes:
  - name: spiffe-socket
    hostPath:
      path: /run/spire/agent-sockets
      type: DirectoryOrCreate
```

**Key Points:**
- hostPath allows the socket to be shared with the CSI driver
- Socket created at: `/run/spire/agent-sockets/socket`
- Persistent across tbot pod restarts (on node filesystem)

### 2. tbot-config.yaml

Configures tbot to provide the SPIFFE Workload API:

```yaml
services:
  - type: workload-identity-api
    # CRITICAL: Use CSI driver standard path
    listen: unix:///run/spire/agent-sockets/socket
    selector:
      name: istio-workloads
    attestors:
      kubernetes:
        enabled: true
        kubelet:
          secure_port: 10250
          token_path: "/var/run/secrets/kubernetes.io/serviceaccount/token"
          ca_path: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
```

**Key Points:**
- Socket path must match what CSI driver expects
- Kubernetes attestor validates pod identity via Kubelet API
- References WorkloadIdentity resource: `istio-workloads`

### 3. spiffe-csi-driver.yaml

CSI driver reads from the same hostPath and exposes it as CSI volumes:

```yaml
volumeMounts:
  - mountPath: /spire-agent-socket
    name: spire-agent-socket-dir
    readOnly: true
volumes:
  - name: spire-agent-socket-dir
    hostPath:
      path: /run/spire/agent-sockets  # Same path as tbot
      type: DirectoryOrCreate
```

**CSIDriver Resource:**
```yaml
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  name: "csi.spiffe.io"
spec:
  attachRequired: false          # No block device needed
  podInfoOnMount: true           # Pass pod metadata for verification
  fsGroupPolicy: None            # Don't change socket permissions
  volumeLifecycleModes:
    - Ephemeral                  # Created/destroyed with pod
```

**Key Points:**
- Reads socket from hostPath (same as tbot writes to)
- `podInfoOnMount: true` enables pod identity verification
- Ephemeral volumes = automatic cleanup

### 4. istio-config.yaml - spire template

The `spire` template configures Istio sidecars to use the SPIFFE CSI driver:

```yaml
sidecarInjectorWebhook:
  templates:
    spire: |
      labels:
        spiffe.io/spire-managed-identity: "true"
      spec:
        volumes:
        - name: workload-socket
          csi:
            driver: "csi.spiffe.io"  # Uses CSI driver (not hostPath!)
            readOnly: true
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
            value: "workloadapi"  # Use SPIFFE Workload API (not istiod)
```

**Key Points:**
- Volume uses CSI driver, not emptyDir or hostPath
- `CA_ADDR` points to Unix socket (not istiod service)
- `PILOT_CERT_PROVIDER=workloadapi` tells Istio to use SPIFFE Workload API

### 5. teleport-sidecar.tpl

Custom Istio injection template based on the standard sidecar template, with one critical difference:

```yaml
# Standard sidecar template includes:
volumeMounts:
  - name: workload-certs
    mountPath: /var/run/secrets/workload-spiffe-credentials
volumes:
  - name: workload-certs
    emptyDir: {}

# teleport-sidecar template REMOVES workload-certs
# This allows the spire template to provide the CSI volume instead
```

**Why this is needed:**
- Standard sidecar template creates `workload-certs` as emptyDir
- This conflicts with the `spire` template's CSI volume
- `teleport-sidecar` template omits `workload-certs` entirely
- All other Istio sidecar functionality remains intact

## Purpose of SPIFFE CSI Driver

The SPIFFE CSI driver is **essential** for secure socket sharing. Here's why:

### 1. Security & Authorization

**Without CSI Driver (using hostPath directly):**
```yaml
❌ BAD: Direct hostPath mount
volumes:
  - name: workload-socket
    hostPath:
      path: /run/spire/agent-sockets/socket
      type: Socket
```

**Problems:**
- ❌ Any pod can mount any host path (security risk)
- ❌ No pod verification
- ❌ No namespace isolation
- ❌ Violates principle of least privilege

**With CSI Driver:**
```yaml
✅ GOOD: CSI volume
volumes:
  - name: workload-socket
    csi:
      driver: "csi.spiffe.io"
      readOnly: true
```

**Benefits:**
- ✅ Driver receives pod metadata (`podInfoOnMount: true`)
- ✅ Can verify: pod namespace, service account, pod UID
- ✅ Can implement authorization logic
- ✅ Only authorized pods get access

### 2. Per-Pod Isolation

The CSI driver creates **unique mount points** for each pod:

```
Host socket (shared):
  /run/spire/agent-sockets/socket
    ↓
CSI driver creates per-pod mount:
  /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/workload-socket/mount
    ↓
Container sees it at:
  /run/secrets/workload-spiffe-uds/socket
```

**Benefits:**
- Each pod has isolated mount point
- Kubernetes can track which pods have the volume mounted
- Proper cleanup when pod terminates

### 3. Kubernetes-Native Volume Management

**Lifecycle Management:**
- `volumeLifecycleModes: ["Ephemeral"]` - volume created/destroyed with pod
- `attachRequired: false` - no block device attachment needed
- `fsGroupPolicy: None` - socket permissions preserved
- Automatic cleanup when pod is deleted

**Comparison:**

| Aspect | hostPath | CSI Driver |
|--------|----------|------------|
| **Security** | ❌ Any pod can mount | ✅ Pod verification required |
| **Authorization** | ❌ No access control | ✅ Can implement RBAC |
| **Isolation** | ❌ Shared path | ✅ Per-pod mount points |
| **Lifecycle** | ❌ Manual cleanup | ✅ Automatic cleanup |
| **Portability** | ❌ Hard-coded paths | ✅ Driver abstracts details |
| **Kubernetes-native** | ❌ Bypasses K8s | ✅ Integrated with K8s |

## Deployment Configuration

### Application Deployment Annotations

All sock-shop deployments include:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: front-end
  namespace: sock-shop
spec:
  template:
    metadata:
      annotations:
        inject.istio.io/templates: "teleport-sidecar,spire"
```

**Template Application Order:**
1. **`teleport-sidecar`**: Base Istio sidecar template WITHOUT `workload-certs` volume
2. **`spire`**: Adds CSI volume + workloadapi configuration

**Why Both Templates:**
- `teleport-sidecar` provides all standard Istio sidecar functionality
- `spire` overlays the SPIFFE/CSI-specific configuration
- Together they create a complete sidecar with Teleport workload identity

## Installation Scripts

### istio-install.sh

Installs Istio with the `spire` template:

```bash
istioctl install -f istio-config.yaml -y
```

### add-teleport-template.sh

Adds the `teleport-sidecar` template to Istio's sidecar injector:

```bash
# Reads teleport-sidecar.tpl
# Patches istio-sidecar-injector ConfigMap
# Restarts istiod to load new template
```

**Note:** Must be run after `istio-install.sh` to add the custom template.

## Verification

### Check Pod Configuration

```bash
# Verify CSI volume is used
kubectl get pod -n sock-shop <pod-name> -o jsonpath='{.spec.volumes[?(@.name=="workload-socket")]}'

# Expected output:
{
  "csi": {
    "driver": "csi.spiffe.io",
    "readOnly": true
  },
  "name": "workload-socket"
}
```

### Check Istio Proxy Configuration

```bash
# Verify proxy uses workloadapi
kubectl exec -n sock-shop <pod-name> -c istio-proxy -- env | grep -E "CA_ADDR|PILOT_CERT"

# Expected output:
CA_ADDR=unix:///run/secrets/workload-spiffe-uds/socket
PILOT_CERT_PROVIDER=workloadapi
```

### Check Socket Exists

```bash
kubectl exec -n sock-shop <pod-name> -c istio-proxy -- ls -la /run/secrets/workload-spiffe-uds/

# Expected output shows socket file:
srwxrwxrwx 1 root root 0 <date> socket
```

## Results

✅ **Istio proxy gets X.509-SVIDs from Teleport** (not Istio's built-in CA)
✅ **Secure socket sharing via CSI driver** (not direct hostPath)
✅ **Per-pod isolation and verification**
✅ **Unified identity across Kubernetes + VMs + infrastructure**
✅ **Centralized audit logs in Teleport**
✅ **Automatic certificate rotation via Teleport**

## Architecture Trade-offs

### vs. Native Istio + SPIRE

| Feature | Native Istio + SPIRE | Istio + Teleport (tbot) |
|---------|---------------------|------------------------|
| **Certificate Authority** | SPIRE Server | Teleport (centralized) |
| **Components** | SPIRE Server + Agent | Teleport + tbot |
| **Identity Management** | SPIRE entries | Teleport WorkloadIdentity |
| **Audit Logs** | SPIRE logs | Teleport comprehensive audit |
| **Access Control** | SPIRE ACLs | Teleport RBAC + policies |
| **Unified Identity** | Kubernetes only | Cross-platform (K8s, VMs, SSH, DBs) |
| **Management UI** | None (CLI only) | Teleport Web UI |
| **Complexity** | **Simpler** | **More complex** |
| **Best For** | K8s-only workloads | Hybrid/multi-platform environments |

## References

- Teleport Workload Identity: https://goteleport.com/docs/workload-identity/
- SPIFFE CSI Driver: https://github.com/spiffe/spiffe-csi
- Istio Custom Injection: https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
