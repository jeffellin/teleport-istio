# Installation Guide: Istio + Teleport Workload Identity

This guide provides step-by-step instructions for setting up Teleport Workload Identity integration with Istio on a clean Kubernetes cluster.

## Prerequisites

### Required Tools
- `kubectl` (1.27+)
- `istioctl` (1.28+)
- `tctl` (Teleport admin tool)
- `tsh` (Teleport client)

### Required Access
- Kubernetes cluster admin access
- Teleport cluster admin access
- Authenticated `tsh` session (`tsh login`)

### Verify Prerequisites

```bash
# Check Kubernetes access
kubectl cluster-info

# Check istioctl installation
istioctl version

# Check Teleport authentication
tctl status
```

## Installation Steps

### Choose a delivery model first

You have two supported options for how the Workload API is delivered into pods:

- **Option A: DaemonSet + hostPath** (injector template `sidecar,spire`)
  - tbot runs once per node, writing the SPIFFE socket to `/run/spire/sockets` on the host.
  - Pods mount the hostPath socket via the injector template.
- **Option B: Per-pod sidecar (no hostPath, no DaemonSet)** (injector template `sidecar,spire-sidecar`)
  - A `tbot` sidecar is injected into each pod, writing the SPIFFE socket to an `emptyDir` shared with Envoy.
  - No node-level DaemonSet required.

Pick Option A or Option B now; the token creation in Step 4 and the deployment steps later depend on this choice.

### Step 1: Set Your Kubeconfig (if needed)

If you're using a non-default kubeconfig:

```bash
export KUBECONFIG=/path/to/your/kubeconfig.yaml
kubectl config current-context
```

### Step 2: Install Istio with SPIFFE Integration

Run the automated installation script:

```bash
./istio-install.sh
```

This script will:
- Create the `istio-system` namespace
- Install Istio with SPIFFE configuration
- Configure trust domain as `ellinj.teleport.sh` (must match your Teleport cluster domain)
- Disable path normalization for SPIFFE compatibility
- Deploy istiod and istio-ingressgateway

**Verify Istio installation:**

```bash
kubectl get pods -n istio-system
```

Expected output:
```
NAME                                    READY   STATUS    RESTARTS   AGE
istio-ingressgateway-xxxxxxxxxx-xxxxx   1/1     Running   0          1m
istiod-xxxxxxxxxx-xxxxx                 1/1     Running   0          1m
```

### Step 3: Extract Cluster JWKS

**CRITICAL STEP**: Every Kubernetes cluster has unique JWKS (JSON Web Key Set) used to validate service account tokens. You must extract your cluster's JWKS for Teleport authentication.

```bash
kubectl get --raw /openid/v1/jwks
```

**Example output:**
```json
{"keys":[{"use":"sig","kty":"RSA","kid":"lgRxZ4gmqOUOvCYs4UvaGe_mGsU_xFP60CtzEgT3BFU","alg":"RS256","n":"yjDQbEkltgSNEAZattubid7Uo5fWKrcgoJ3ZQSfWa9_9cLberxef8p0qC4Ss6atMfPMWI5N1_b59LG5ulnXFB0jGl5yjpn20bUOr_7In3-1caBp8yGD9bMPaZ8VAdKhMAAJXnXZTsW33URKiM8C53GE4DmYZJ6neksNCzbQqV8s1g7E96xVE0tmAJu4ZlWksIIRkbNvCx4oZNFcsl4W15jfFuBD2J5DT92UiG_xj-B9Z60ckT_AxND0cRud9aqrsep5YqaW5mGNG3mpt6460oEqWKgrteI8WvdheIZySxpaJOmvnh3kcLK6CxYfByNYbDmmjoCTqzLQ9CyclmJ3ckw","e":"AQAB"}]}
```

**Copy this entire JSON output** - you'll need it in the next step.

### Step 4: Create Kubernetes Join Token with Cluster JWKS

**SECURITY NOTE**: Token files contain cluster-specific JWKS and are gitignored. Do not commit them.**

- **If you are using Option A (DaemonSet / `sidecar,spire`)**  
  - Recommended: `./create-token.sh` (generates `istio-tbot-token.yaml` from JWKS)  
  - Or manual: copy `istio-tbot-token.yaml.template` → `istio-tbot-token.yaml`, inject JWKS, then `tctl create -f istio-tbot-token.yaml`  
  - Verify: `tctl get token/istio-tbot-k8s-join`

- **If you are using Option B (per-pod sidecar / `sidecar,spire-sidecar`)**  
  - Recommended: `./create-sidecar-token.sh` (generates `istio-tbot-sidecar-token.yaml` from JWKS)  
  - Or manual: copy `istio-tbot-sidecar-token.yaml.template` → `istio-tbot-sidecar-token.yaml`, inject JWKS and adjust the service_account allowlist, then `tctl create -f istio-tbot-sidecar-token.yaml`  
  - Verify: `tctl get token/istio-sidecar-k8s-join`

### Step 5: Create Teleport Bot Role

This role grants the bot permission to issue workload identities.

```bash
tctl create -f teleport-bot-role.yaml
```

**Verify role creation:**

```bash
tctl get role/istio-workload-identity-issuer
```

### Step 6: Create Workload Identity Resource

This defines the SPIFFE ID template for Kubernetes workloads.

**IMPORTANT**: The SPIFFE ID template must match Istio's expected format with `/sa/`:
```
spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>
```

```bash
tctl create -f teleport-workload-identity.yaml
```

**Verify workload identity:**

```bash
tctl get workload_identity/istio-workloads
```

The template should show:
```yaml
spec:
  spiffe:
    id: /ns/{{ workload.kubernetes.namespace }}/sa/{{ workload.kubernetes.service_account }}
```

Note the `/sa/` component is critical for Istio compatibility.

### Step 7: Choose how to deliver the Workload API (DaemonSet vs per-pod sidecar)

**Option A: DaemonSet (node-level, hostPath)** — continue to Step 8 after completing this option.

Deploy tbot as a DaemonSet that writes the SPIFFE socket to `/run/spire/sockets` on each node (works with the `spire` injector template).

```bash
# Create namespace, service account, and RBAC
kubectl apply -f tbot-rbac.yaml

# Create tbot configuration
kubectl apply -f tbot-config.yaml

# Deploy tbot DaemonSet
kubectl apply -f tbot-daemonset.yaml
```

Verify DaemonSet:
```bash
kubectl get pods -n teleport-system
kubectl logs -n teleport-system <tbot-pod-name>
```

Expected: one pod per node, logs show `Listener opened for Workload API endpoint`.

**Option B: Per-pod sidecar (no hostPath, no DaemonSet)** — skip Step 8 and go directly to Step 9 after completing this option.

Deliver the Workload API via the injector template `spire-sidecar`, which injects a `tbot` container into each workload pod and shares an `emptyDir` socket volume with Envoy.

1) Create the sidecar token from `istio-tbot-sidecar-token.yaml.template` (add JWKS and allowed namespaces/service accounts), then `tctl create -f istio-tbot-sidecar-token.yaml`. The token name must match `onboarding.token` in your ConfigMap.
2) For each namespace, create a ConfigMap from `tbot-sidecar-config.yaml` with your Teleport address, token name, selector, and namespace.
3) Annotate the namespace or workload with `inject.istio.io/templates: "sidecar,spire-sidecar"`.
4) Skip applying the DaemonSet manifests (`tbot-daemonset.yaml`); the injector will add the sidecar automatically to each pod.

### Step 8: Deploy Test Application (DaemonSet path only)

Deploy a sample application with Istio sidecar injection:

```bash
kubectl apply -f test-app-deployment.yaml
```

This step is for the DaemonSet path (Option A). If you are using the per-pod sidecar path (Option B), skip to Step 9 and deploy your workloads with the `sidecar,spire-sidecar` annotation plus the ConfigMap/token prerequisites.

If you are on Option A, deploy a sample application with Istio sidecar injection:

```bash
kubectl apply -f test-app-deployment.yaml
```

Notes for Option A:
- Set `inject.istio.io/templates: "sidecar,spire"` if you are using the DaemonSet.
- Ensure the DaemonSet is running and the hostPath socket is available on the node.

**Verify test application:**

```bash
kubectl get pods -n test-app
```

Expected output:
```
NAME                        READY   STATUS    RESTARTS   AGE
test-app-xxxxxxxxxx-xxxxx   2/2     Running   0          1m
```

Note: `2/2` indicates both the application container and Istio sidecar are running.

### Step 9: Verify SPIFFE Integration (both paths)

Check that the SPIFFE socket is available in the pod:

```bash
# Get pod name
export POD_NAME=$(kubectl get pod -n test-app -l app=test-app -o jsonpath='{.items[0].metadata.name}')

# Check SPIFFE socket
kubectl exec -n test-app $POD_NAME -c istio-proxy -- ls -la /var/run/secrets/workload-spiffe-uds/
```

Expected output:
```
total 4
drwxr-xr-x 2 root root   60 Dec  5 17:14 .
drwxr-xr-x 8 root root 4096 Dec  5 17:15 ..
srwxrwxrwx 1 root root    0 Dec  5 17:14 socket
```

**Check Istio proxy logs:**

```bash
kubectl logs -n test-app $POD_NAME -c istio-proxy | grep -i "spiffe\|workload"
```

Expected output:
```
Existing workload SDS socket found at var/run/secrets/workload-spiffe-uds/socket
Workload is using file mounted certificates
```

## Configuration Details

### Teleport Configuration (tbot-config.yaml)

Key settings:
```yaml
proxy_server: your-teleport-cluster.teleport.sh:443
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
```

**Update `proxy_server`** to match your Teleport cluster address.

### Istio Configuration (istio-config.yaml)

Key settings:
```yaml
meshConfig:
  trustDomain: ellinj.teleport.sh  # Must match your Teleport cluster domain
  pathNormalization:
    normalization: NONE
```

**CRITICAL**: The `trustDomain` must match your Teleport cluster domain. Replace `ellinj.teleport.sh` with your actual Teleport cluster address without the port.

## Troubleshooting

### Issue: tbot pods in CrashLoopBackOff with JWT validation error

**Symptoms:**
```
ERROR: reviewing kubernetes token with static_jwks
validating jwt signature
go-jose/go-jose: unsupported key type/format
```

**Solution:**
The JWKS in your token doesn't match the cluster. Re-extract the JWKS and update the token:

```bash
# Get current cluster JWKS and update token file
kubectl get --raw /openid/v1/jwks | \
  sed 's/"/\\"/g' | \
  xargs -I {} sed -i.bak "s|jwks: '.*'|jwks: '{}'|" istio-tbot-token.yaml

# Clean up backup file
rm istio-tbot-token.yaml.bak

# Force update the token in Teleport
tctl create -f istio-tbot-token.yaml --force

# Restart tbot pods to pick up new token
kubectl delete pods -n teleport-system -l app=tbot
```

Note: If `istio-tbot-token.yaml` doesn't exist, recreate it from the template:
```bash
cp istio-tbot-token.yaml.template istio-tbot-token.yaml
# Then run the commands above
```

### Issue: tbot pods not finding Teleport cluster

**Symptoms:**
```
ERROR: connection refused
```

**Solution:**
1. Verify Teleport cluster address in `tbot-config.yaml`
2. Check network connectivity from cluster to Teleport
3. Verify firewall rules allow outbound HTTPS (port 443)

```bash
# Test connectivity from a pod
kubectl run -it --rm debug --image=alpine --restart=Never -- sh -c "apk add curl && curl -v https://your-cluster.teleport.sh:443"
```

### Issue: Istio proxy not detecting SPIFFE socket

**Symptoms:**
Istio proxy logs don't mention workload socket

**Solution:**
1. Verify tbot is running on the same node as your application:

```bash
# Get app pod node
kubectl get pod -n test-app $POD_NAME -o jsonpath='{.spec.nodeName}'

# Get tbot pods and their nodes
kubectl get pods -n teleport-system -o wide
```

2. Check tbot logs for errors:

```bash
kubectl logs -n teleport-system <tbot-pod-on-same-node>
```

3. Verify volume mounts in test-app-deployment.yaml

### Issue: Application pod stuck in Init state

**Symptoms:**
```
test-app-xxxxxxxxxx-xxxxx   0/2     Init:0/1   0          30s
```

**Solution:**
Check init container logs:

```bash
kubectl logs -n test-app $POD_NAME -c istio-init
```

Verify Istio injection is enabled:

```bash
kubectl get namespace test-app -o jsonpath='{.metadata.labels.istio-injection}'
```

Should output: `enabled`

### Issue: Permission denied accessing SPIFFE socket

**Symptoms:**
Istio proxy can't access `/run/spire/sockets/socket`

**Solution:**
Verify volume mounts and tbot DaemonSet configuration:

```bash
kubectl describe pod -n test-app $POD_NAME
```

Check for `workload-spiffe-uds` volume mounted at `/var/run/secrets/workload-spiffe-uds`

## Verification Checklist

After installation, verify each component:

- [ ] Istio installed: `kubectl get pods -n istio-system`
- [ ] Teleport token created: `tctl get token/istio-tbot-k8s-join`
- [ ] If using sidecar delivery: sidecar token created: `tctl get token/istio-sidecar-k8s-join`
- [ ] Bot role created: `tctl get role/istio-workload-identity-issuer`
- [ ] Workload identity created: `tctl get workload_identity/istio-workloads`
- [ ] Workload API provider running: either DaemonSet tbot pods (`kubectl get pods -n teleport-system`) or injected tbot sidecars in your workloads
- [ ] If using DaemonSet: tbot logs show no errors: `kubectl logs -n teleport-system <pod-name>`
- [ ] Test app running with 2/2 containers: `kubectl get pods -n test-app`
- [ ] SPIFFE socket exists in pod: `kubectl exec` command succeeds
- [ ] Istio proxy detects socket: Check proxy logs

## Next Steps

After successful installation:

1. Deploy your own applications with Istio injection:
   ```yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: your-namespace
     labels:
       istio-injection: enabled
   ```

2. Verify workload identities:
   ```bash
   kubectl logs -n your-namespace <pod-name> -c istio-proxy | grep SPIFFE
   ```

3. Configure Istio policies (AuthorizationPolicy, PeerAuthentication, etc.)

4. Monitor workload identity usage in Teleport audit logs

## Support

For issues or questions:
- Teleport documentation: https://goteleport.com/docs/
- Istio documentation: https://istio.io/latest/docs/
- SPIFFE specification: https://github.com/spiffe/spiffe

## Important Notes

1. **Token file security**: The `istio-tbot-token.yaml` file contains sensitive cluster-specific JWKS and is gitignored. NEVER commit this file to version control. Always use the `.template` file for reference.
2. **JWKS is cluster-specific**: Always extract JWKS from your target cluster. Each cluster has unique keys.
3. **Token security**: The join token allows any pod with `teleport-system:tbot` service account to join Teleport. Protect this service account accordingly.
4. **Trust domain**: Must match between Istio and Teleport (use your Teleport cluster domain, e.g., `yourcluster.teleport.sh`)
5. **SPIFFE ID format**: Must include `/sa/` component: `/ns/<namespace>/sa/<service-account>` for Istio compatibility
6. **Path normalization**: Must be `NONE` for SPIFFE compatibility
7. **Socket path**: `/run/spire/sockets/socket` is the standard SPIFFE location
8. **No trailing slashes**: SPIFFE IDs must not have trailing slashes per spec
9. **Restart after changes**: After updating WorkloadIdentity or tbot config, restart tbot pods: `kubectl rollout restart daemonset -n teleport-system tbot`
