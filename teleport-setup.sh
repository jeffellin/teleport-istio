#!/bin/bash
set -e

echo "=== Teleport Resources Setup Script ==="
echo ""

# Check if tctl is available
if ! command -v tctl &>/dev/null; then
    echo "ERROR: tctl not found"
    echo "Please install tctl or ensure it's in your PATH"
    exit 1
fi

echo "Using tctl version: $(tctl version 2>&1 | head -1)"
echo ""

# Check if we're connected to Teleport
echo "Checking Teleport connection..."
if ! tctl status &>/dev/null; then
    echo "ERROR: Cannot connect to Teleport cluster"
    echo "Please log in to Teleport first"
    exit 1
fi

echo "Connected to Teleport cluster:"
tctl status
echo ""

# Create WorkloadIdentity resource
echo "=== Creating WorkloadIdentity resource ==="
if tctl get workload_identity/istio-workloads &>/dev/null; then
    echo "WorkloadIdentity 'istio-workloads' already exists, updating..."
    tctl create -f teleport-workload-identity.yaml --force
else
    echo "Creating new WorkloadIdentity 'istio-workloads'..."
    tctl create -f teleport-workload-identity.yaml
fi

echo ""
echo "Verifying WorkloadIdentity:"
tctl get workload_identity/istio-workloads --format=yaml | grep -A 5 "spec:"
echo ""

# Create or update the bot role
echo "=== Creating Bot Role ==="
if tctl get role/istio-workload-identity-issuer &>/dev/null; then
    echo "Role 'istio-workload-identity-issuer' already exists, updating..."
    tctl create -f teleport-bot-role.yaml --force
else
    echo "Creating new role 'istio-workload-identity-issuer'..."
    tctl create -f teleport-bot-role.yaml
fi

echo ""
echo "Verifying role:"
tctl get role/istio-workload-identity-issuer --format=yaml | grep -A 10 "spec:"
echo ""

# Check if bot already exists
echo "=== Checking Bot Configuration ==="
if tctl bots ls | grep -q istio-tbot; then
    echo "Bot 'istio-tbot' already exists"
    echo ""
    echo "Bot details:"
    tctl bots ls | grep -A 2 istio-tbot
else
    echo "Bot 'istio-tbot' does not exist"
    echo ""
    echo "To create the bot, run:"
    echo "  tctl bots add istio-tbot --roles=istio-workload-identity-issuer"
    echo ""
    read -p "Create the bot now? (yes/no): " create_bot
    if [ "$create_bot" == "yes" ]; then
        tctl bots add istio-tbot --roles=istio-workload-identity-issuer
        echo "✓ Bot created successfully"
    else
        echo "Skipping bot creation - you'll need to create it manually"
    fi
fi

echo ""

# Check if join token exists
echo "=== Checking Join Token ==="
if tctl get token/istio-tbot-token &>/dev/null; then
    echo "Join token 'istio-tbot-token' already exists"
    echo ""
    echo "Token details:"
    tctl get token/istio-tbot-token --format=yaml | grep -A 5 "spec:"
else
    echo "Join token 'istio-tbot-token' does not exist"
    echo ""
    echo "Creating join token for Kubernetes..."

    cat <<EOF | tctl create -f -
kind: token
version: v2
metadata:
  name: istio-tbot-token
spec:
  roles:
    - Bot
  join_method: kubernetes
  bot_name: istio-tbot
  kubernetes:
    type: static_jwks
    allow:
      - service_account: "teleport-system:tbot"
EOF

    echo "✓ Join token created successfully"
fi

echo ""
echo "=== Teleport Resources Setup Complete ==="
echo ""
echo "Resources created:"
echo "  ✓ WorkloadIdentity: istio-workloads"
echo "  ✓ Role: istio-workload-identity-issuer"
echo "  ✓ Bot: istio-tbot (check above)"
echo "  ✓ Join Token: istio-tbot-token"
echo ""
echo "Ready to deploy tbot to Kubernetes!"
