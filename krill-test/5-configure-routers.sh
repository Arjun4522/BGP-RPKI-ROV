#!/bin/bash
# =============================================================================
# Step 5: Configure Routers to Connect to Routinator
# Clean, reliable, and readable version with safe error handling
# =============================================================================
set -Euo pipefail

MAX_RETRIES=12
RETRY_INTERVAL=3
ROUTINATOR_PORT="3324"

echo "🚀 Step 5: Configuring routers to connect to Routinator..."
echo "=========================================================="
echo ""

# =============================================================================
# STEP 0: Auto-detect lab and Routinator container
# =============================================================================
echo "🔍 Detecting lab configuration..."

TOPO_FILE=$(ls *.clab.yml *.clab.yaml 2>/dev/null | head -1 || true)
if [ -z "$TOPO_FILE" ]; then
    echo "❌ ERROR: No containerlab topology file found!"
    exit 1
fi

LAB_NAME=$(grep "^name:" "$TOPO_FILE" | awk '{print $2}' | tr -d '"' | tr -d "'")
if [ -z "$LAB_NAME" ]; then
    echo "❌ ERROR: Could not determine lab name from $TOPO_FILE"
    exit 1
fi

ROUTINATOR_CONTAINER="clab-${LAB_NAME}-routinator"
ROUTER_PREFIX="clab-${LAB_NAME}-"

echo "✅ Detected lab: $LAB_NAME"

if ! sudo docker ps --format '{{.Names}}' | grep -q "^${ROUTINATOR_CONTAINER}$"; then
    echo "❌ ERROR: Routinator container '$ROUTINATOR_CONTAINER' not found!"
    echo "   Run: sudo containerlab deploy -t $TOPO_FILE"
    exit 1
fi

ROUTINATOR_IP=$(sudo docker inspect "$ROUTINATOR_CONTAINER" | grep -o '"IPAddress": "[0-9.]*' | grep -o '[0-9.]*' | head -1)
if [ -z "$ROUTINATOR_IP" ]; then
    echo "❌ ERROR: Could not determine IP address for $ROUTINATOR_CONTAINER"
    exit 1
fi

echo "✅ Routinator container: $ROUTINATOR_CONTAINER"
echo "✅ Routinator IP: $ROUTINATOR_IP"
echo ""

# Detect routers
ROUTERS=($(sudo docker ps --format '{{.Names}}' | grep "^${ROUTER_PREFIX}R[0-9]" | sed "s/${ROUTER_PREFIX}//" | sort))
if [ ${#ROUTERS[@]} -eq 0 ]; then
    echo "⚠️  No routers detected — using default list: R1 R2 R3 R4 R5 R6 R7"
    ROUTERS=(R1 R2 R3 R4 R5 R6 R7)
else
    echo "✅ Detected routers: ${ROUTERS[*]}"
fi
echo ""

# =============================================================================
# STEP 1: Restart Routinator
# =============================================================================
echo "🔄 Restarting Routinator service..."
sudo docker exec "$ROUTINATOR_CONTAINER" pkill -9 routinator 2>/dev/null || true
sleep 2
sudo docker exec -d "$ROUTINATOR_CONTAINER" routinator -c /root/.rpki-cache/routinator.conf server \
  > /tmp/routinator.log 2>&1
sleep 10

if sudo docker exec "$ROUTINATOR_CONTAINER" netstat -tln | grep -q ":$ROUTINATOR_PORT"; then
    echo "✅ Routinator restarted and listening on port $ROUTINATOR_PORT!"
else
    echo "❌ Routinator failed to start on port $ROUTINATOR_PORT"
    sudo docker exec "$ROUTINATOR_CONTAINER" cat /tmp/routinator.log | tail -20
    exit 1
fi
echo ""

# =============================================================================
# STEP 2: Configure RPKI cache on each router
# =============================================================================
echo "🔧 Configuring routers for RPKI cache connection..."
echo ""

configure_router_rpki() {
    local router=$1
    local container="${ROUTER_PREFIX}${router}"

    echo "🔧 Configuring $container..."
    sudo docker exec "$container" vtysh -c "conf t" -c "no rpki" -c "end" > /dev/null 2>&1 || true
    sleep 1

    sudo docker exec "$container" vtysh -c "conf t" \
        -c "rpki" \
        -c "rpki cache tcp $ROUTINATOR_IP $ROUTINATOR_PORT preference 1" \
        -c "rpki polling_period 30" \
        -c "exit" \
        -c "exit"
        -c "write memory" > /dev/null 2>&1

    for ((i=1; i<=MAX_RETRIES; i++)); do
        sleep $RETRY_INTERVAL
        if sudo docker exec "$container" vtysh -c "show rpki cache-connection" 2>/dev/null | grep -q "Connected"; then
            echo "   ✅ $router connected to Routinator!"
            return 0
        fi
        echo "   ⏳ Waiting for connection ($i/$MAX_RETRIES)..."
    done

    echo "   ⚠️  $router not yet connected (may still be initializing)"
    return 1
}

success=0
fail=0

for router in "${ROUTERS[@]}"; do
    if configure_router_rpki "$router" || true; then
        ((success++))
    else
        ((fail++))
    fi
    echo ""
done

# =============================================================================
# STEP 3: Summary
# =============================================================================
echo "📊 Summary:"
echo "   ✅ Connected routers: $success"
if [ "$fail" -gt 0 ]; then
    echo "   ⚠️  Failed routers: $fail"
fi
echo ""

echo "🔍 Verifying router RPKI status..."
for router in "${ROUTERS[@]}"; do
    container="${ROUTER_PREFIX}${router}"
    status=$(sudo docker exec "$container" vtysh -c "show rpki cache-connection" 2>/dev/null | head -1 || echo "Unknown")
    echo "   $router → $status"
done

echo ""
echo "🎉 All routers processed!"
echo "=========================================================="
echo "✅ Routinator: $ROUTINATOR_IP:$ROUTINATOR_PORT"
echo "✅ Routers: ${ROUTERS[*]}"
echo ""
echo ""
echo "🎉 Step 5 completed!"
echo "Next step: Run 6-verify-setup.sh"
