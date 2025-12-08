#!/bin/bash
# Helper script to create Teleport join token for sidecar-delivered Workload API
# Generates istio-tbot-sidecar-token.yaml from the template using cluster JWKS.
#
# The generated istio-tbot-sidecar-token.yaml file is gitignored and should NOT be committed.

set -e

echo "=== Teleport Sidecar Join Token Creation Script ==="
echo ""

TEMPLATE="istio-tbot-sidecar-token.yaml.template"
OUTPUT="istio-tbot-sidecar-token.yaml"

if [ ! -f "$TEMPLATE" ]; then
    echo "ERROR: $TEMPLATE not found. Run this script from the project root."
    exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster. Check kubeconfig/permissions."
    exit 1
fi

echo "Current cluster: $(kubectl config current-context)"
echo ""

if [ -f "$OUTPUT" ]; then
    echo "WARNING: $OUTPUT already exists"
    read -p "Do you want to overwrite it? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

echo "=== Extracting cluster JWKS ==="
JWKS=$(kubectl get --raw /openid/v1/jwks)

if [ -z "$JWKS" ]; then
    echo "ERROR: Failed to extract JWKS from cluster"
    exit 1
fi

echo "Successfully extracted JWKS"
echo ""
echo "Reminder: update the service_account allowlist in $OUTPUT if you need namespaces beyond the defaults in the template."

echo "=== Creating $OUTPUT ==="
cp "$TEMPLATE" "$OUTPUT"

ESCAPED_JWKS=$(echo "$JWKS" | sed 's/"/\\"/g')

if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|'PASTE_JWKS_HERE'|'$ESCAPED_JWKS'|" "$OUTPUT"
else
    sed -i "s|'PASTE_JWKS_HERE'|'$ESCAPED_JWKS'|" "$OUTPUT"
fi

echo "Successfully created $OUTPUT"
echo ""
echo "=== Next Steps ==="
echo "1. Review the generated file: cat $OUTPUT"
echo "   - Ensure the service_account allowlist covers your sidecar namespaces/SAs (e.g., test-app:*)."
echo "2. Create the token in Teleport: tctl create -f $OUTPUT"
echo "3. Verify token creation: tctl get token/istio-sidecar-k8s-join"
echo ""
echo "IMPORTANT: $OUTPUT is gitignored and should NOT be committed (contains cluster-specific JWKS)"
