#!/bin/bash
set -e

echo "=== Adding Teleport Sidecar Template to Istio ==="

# Change to script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f "teleport-sidecar.tpl" ]; then
    echo "ERROR: teleport-sidecar.tpl not found"
    exit 1
fi

echo "Reading teleport-sidecar template..."
TEMPLATE_CONTENT=$(cat teleport-sidecar.tpl)

echo "Backing up current configmap..."
kubectl get configmap istio-sidecar-injector -n istio-system -o yaml > /tmp/istio-sidecar-injector-backup.yaml

echo "Extracting current config..."
kubectl get configmap istio-sidecar-injector -n istio-system -o jsonpath='{.data.config}' > /tmp/istio-config-current.txt

# Check if teleport-sidecar is already in templates
if grep -q "teleport-sidecar:" /tmp/istio-config-current.txt; then
    echo "Teleport-sidecar template already exists, updating it..."
    # Extract everything before teleport-sidecar template
    awk '/^  teleport-sidecar: \|/{exit} {print}' /tmp/istio-config-current.txt > /tmp/istio-config-new.txt
    # Add the new template
    echo "  teleport-sidecar: |" >> /tmp/istio-config-new.txt
    sed 's/^/    /' teleport-sidecar.tpl >> /tmp/istio-config-new.txt
    # Add everything after the old teleport-sidecar template
    awk '/^  teleport-sidecar: \|/{flag=1} flag && /^  [a-z]/{flag=0} !flag && /^  [a-z]/' /tmp/istio-config-current.txt | tail -n +2 >> /tmp/istio-config-new.txt
else
    echo "Adding new teleport-sidecar template..."
    # Add teleport-sidecar to templates section
    awk '/^templates:/{print; print "  teleport-sidecar: |"; system("sed \"s/^/    /\" teleport-sidecar.tpl"); next} {print}' /tmp/istio-config-current.txt > /tmp/istio-config-new.txt

    # Add to defaultTemplates if not there
    if ! grep -q "- teleport-sidecar" /tmp/istio-config-new.txt; then
        sed -i.bak '/^defaultTemplates:/a\
- teleport-sidecar' /tmp/istio-config-new.txt
    fi
fi

echo "Applying updated config..."
kubectl create configmap istio-sidecar-injector -n istio-system --from-file=config=/tmp/istio-config-new.txt --dry-run=client -o yaml | \
  kubectl patch configmap istio-sidecar-injector -n istio-system --patch-file=/dev/stdin

echo "Restarting istiod to pick up new template..."
kubectl rollout restart deployment/istiod -n istio-system
kubectl rollout status deployment/istiod -n istio-system --timeout=120s

echo ""
echo "✓ Teleport sidecar template added successfully"
echo ""
echo "Available templates:"
kubectl get configmap istio-sidecar-injector -n istio-system -o jsonpath='{.data.config}' | grep "^  [a-z-]*:" | sed 's/:.*//; s/^  /  - /'
