./istio-install.sh
./create-token.sh

# Deploy SPIFFE CSI driver (needed for workload-socket mounts)

tctl create -f istio-tbot-token.yaml
tctl get token/istio-tbot-k8s-join
tctl create -f teleport-bot-role.yaml
tctl get role/istio-workload-identity-issuer
tctl create -f teleport-workload-identity.yaml
tctl get workload_identity/istio-workloads


# Create namespace, service account, and RBAC
kubectl apply -f tbot-rbac.yaml

# Create tbot configuration
kubectl apply -f tbot-config.yaml

kubectl apply -f spiffe-csi-driver.yaml

# Deploy tbot DaemonSet
kubectl apply -f tbot-daemonset.yaml

kubectl apply -f sock-shop-demo.yaml
kubectl apply -f sock-shop-policies.yaml
