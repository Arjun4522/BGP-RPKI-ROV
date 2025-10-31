#!/bin/bash

# =============================================================================
# Step 5: Configure routers to connect to Routinator (with fixes)
# =============================================================================

set -e

echo "🚀 Step 5: Configuring routers to connect to Routinator..."
echo "=========================================================="
echo ""

# Auto-detect lab configuration
TOPO_FILE="krill-test.clab.yml"

if [ ! -f "$TOPO_FILE" ]; then
    echo "❌ ERROR: Topology file $TOPO_FILE not found!"
    exit 1
fi

# Extract lab name from topology file
LAB_NAME=$(grep "^name:" "$TOPO_FILE" | awk '{print $2}' | tr -d '"' | tr -d "'")
if [ -z "$LAB_NAME" ]; then
    echo "❌ ERROR: Could not determine lab name from $TOPO_FILE"
    exit 1
fi

echo "✅ Detected lab: $LAB_NAME"

# Construct container names
ROUTINATOR_CONTAINER=$(sudo docker ps --format '{{.Names}}' | grep "${LAB_NAME}-routinator" | head -1)
ROUTER_PREFIX="clab-${LAB_NAME}-"

if [ -z "$ROUTINATOR_CONTAINER" ]; then
    echo "❌ ERROR: Routinator container not found!"
    exit 1
fi

echo "✅ Routinator container: $ROUTINATOR_CONTAINER"

# Get Routinator IP address
ROUTINATOR_IP=$(sudo docker inspect "$ROUTINATOR_CONTAINER" 2>/dev/null | grep -o '"IPAddress": "[^"]*' | grep -o '[0-9.]*$' | head -1)

if [ -z "$ROUTINATOR_IP" ]; then
    echo "❌ ERROR: Could not determine IP address for $ROUTINATOR_CONTAINER"
    exit 1
fi

echo "✅ Routinator IP: $ROUTINATOR_IP"
echo ""

# Detect router list from running containers
ROUTERS=()
while IFS= read -r container_name; do
    router_name=$(echo "$container_name" | sed "s/${ROUTER_PREFIX}//")
    ROUTERS+=("$router_name")
done < <(sudo docker ps --format '{{.Names}}' | grep "^${ROUTER_PREFIX}R[0-9]" | sort)

if [ ${#ROUTERS[@]} -eq 0 ]; then
    echo "⚠️  WARNING: No routers found with pattern ${ROUTER_PREFIX}R*"
    echo "   Will use default: R1 R2 R3 R4 R5 R6 R7"
    ROUTERS=(R1 R2 R3 R4 R5 R6 R7)
else
    echo "✅ Detected routers: ${ROUTERS[*]}"
fi
echo ""

# Fix Routinator first - aggressive process termination
echo "🛑 Step 5a: Stopping Routinator gracefully..."
echo "   Sending SIGTERM to routinator processes..."
sudo docker exec "$ROUTINATOR_CONTAINER" pkill -15 routinator 2>/dev/null || true
sleep 2

echo "   Force-killing any remaining processes..."
sudo docker exec "$ROUTINATOR_CONTAINER" pkill -9 routinator 2>/dev/null || true
sleep 2

# Final sanity check
if sudo docker exec "$ROUTINATOR_CONTAINER" pgrep -f routinator >/dev/null 2>&1; then
    echo "   ⚠️  Routinator still running – final killall..."
    sudo docker exec "$ROUTINATOR_CONTAINER" killall -9 routinator 2>/dev/null || true
    sleep 2
fi

echo "✅ Routinator stopped"
echo ""

echo "🚀 Step 5b: Starting Routinator with explicit config on port 3324..."
sudo docker exec -d "$ROUTINATOR_CONTAINER" \
    routinator --config /root/.rpki-cache/routinator.conf server \
    > /tmp/routinator.log 2>&1

echo "⏳ Waiting for Routinator to start (15 seconds)..."
sleep 15

# Port-readiness loop with retries
echo "🔍 Verifying Routinator is listening on port 3324..."
MAX_RETRIES=20
RETRY_INTERVAL=3
retry_count=0
routinator_started=false

while [ $retry_count -lt $MAX_RETRIES ]; do
    if sudo docker exec "$ROUTINATOR_CONTAINER" netstat -tln 2>/dev/null | grep -q ":3324"; then
        echo "✅ Routinator is listening on port 3324!"
        routinator_started=true
        break
    fi
    retry_count=$((retry_count + 1))
    echo "   ⏳ Attempt $retry_count/$MAX_RETRIES..."
    sleep $RETRY_INTERVAL
done

if [ "$routinator_started" = false ]; then
    echo "❌ ERROR: Routinator failed to start on port 3324"
    echo ""
    echo "📋 Routinator logs:"
    sudo docker logs "$ROUTINATOR_CONTAINER" --tail 30
    echo ""
    echo "🔍 Port status:"
    sudo docker exec "$ROUTINATOR_CONTAINER" netstat -tln 2>/dev/null || echo "netstat not available"
    echo ""
    echo "🔍 Process status:"
    sudo docker exec "$ROUTINATOR_CONTAINER" ps aux | grep routinator || echo "No routinator process found"
    exit 1
fi

echo ""
echo "📊 Routinator process status:"
sudo docker exec "$ROUTINATOR_CONTAINER" ps aux | grep -v grep | grep routinator || echo "Process list not available"
echo ""

# Verify Routinator is running correctly
if sudo docker exec "$ROUTINATOR_CONTAINER" pgrep -f routinator >/dev/null 2>&1; then
    echo "✅ Routinator is running with correct config"
else
    echo "❌ ERROR: Routinator process not found"
    echo "📋 Logs:"
    sudo docker logs "$ROUTINATOR_CONTAINER" --tail 20
    exit 1
fi

# Check for errors in Routinator startup
echo "📋 Checking Routinator startup logs..."
sleep 2
ROUTINATOR_ERRORS=$(sudo docker logs "$ROUTINATOR_CONTAINER" --tail 15 2>&1 | grep -i "ERROR" || true)
if [ -n "$ROUTINATOR_ERRORS" ]; then
    echo "⚠️  WARNING: Routinator has errors:"
    echo "$ROUTINATOR_ERRORS"
else
    echo "✅ No errors in Routinator logs"
fi

echo ""
echo "⏳ Waiting for RPKI data to load (25 seconds)..."
sleep 25
echo ""

# Restart FRR on all routers to clear any stale state
echo "🔄 Restarting FRR daemons on all routers to clear stale connections..."
for router in "${ROUTERS[@]}"; do
    container="${ROUTER_PREFIX}${router}"
    echo "   Restarting FRR on $router..."
    sudo docker exec "$container" /etc/init.d/frr restart > /dev/null 2>&1 || true
done

echo "⏳ Waiting for FRR to restart (15 seconds)..."
sleep 15
echo "✅ FRR restarted on all routers"
echo ""

configure_router_rpki() {
    local router=$1
    local container="${ROUTER_PREFIX}${router}"
    echo "   Configuring $router..."
    
    # Clear existing RPKI config
    sudo docker exec "$container" vtysh \
        -c "config" \
        -c "no rpki" \
        -c "exit" > /dev/null 2>&1 || true
    
    sleep 2
    
    # Configure RPKI with TCP connection on port 3324
    sudo docker exec "$container" vtysh \
        -c "config" \
        -c "rpki" \
        -c "rpki cache tcp $ROUTINATOR_IP 3324 preference 1" \
        -c "rpki polling_period 30" \
        -c "exit" \
        -c "exit" \
        -c "write memory" > /dev/null 2>&1
    
    # Force RPKI reset to initiate connection
    sudo docker exec "$container" vtysh -c "rpki reset" > /dev/null 2>&1 || true
    
    # Verify connection with retries
    local connected=false
    for i in {1..15}; do
        sleep 3
        if sudo docker exec "$container" vtysh -c 'show rpki cache-connection' 2>/dev/null | grep -q "Connected"; then
            echo "      ✅ $router connected to RPKI cache"
            connected=true
            break
        fi
        [ $i -lt 15 ] && echo "      ⏳ $router connection attempt $i/15..."
    done
    
    if [ "$connected" = false ]; then
        echo "      ⚠️  $router failed to connect to RPKI cache"
        echo "      🔍 Debugging info:"
        sudo docker exec "$container" vtysh -c 'show rpki cache-connection' 2>&1 | head -10
        sudo docker exec "$container" vtysh -c 'show rpki configuration' 2>&1 | head -10
        return 1
    fi
    return 0
}

# Configure all routers with retry logic
successful_routers=0
failed_routers=0

for router in "${ROUTERS[@]}"; do
    retry_count=0
    router_configured=false
    
    while [ $retry_count -lt 2 ]; do
        if configure_router_rpki "$router"; then
            router_configured=true
            successful_routers=$((successful_routers + 1))
            break
        fi
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt 2 ]; then
            echo "      🔄 Retrying $router configuration..."
            sleep 5
        fi
    done
    
    if [ "$router_configured" = false ]; then
        failed_routers=$((failed_routers + 1))
        echo "      ❌ $router configuration failed after retries"
    fi
    
    echo ""
done

echo "📊 Configuration Summary:"
echo "   ✅ Successfully configured: $successful_routers routers"
if [ $failed_routers -gt 0 ]; then
    echo "   ❌ Failed to configure: $failed_routers routers"
    echo ""
    echo "⚠️  Some routers failed. Check the debug output above."
fi
echo ""

# Show RPKI connection status for all routers
echo "📋 RPKI Connection Status:"
for router in "${ROUTERS[@]}"; do
    container="${ROUTER_PREFIX}${router}"
    echo ""
    echo "=== $router ==="
    sudo docker exec "$container" vtysh -c 'show rpki cache-connection' 2>/dev/null || echo "Failed to get status"
done
echo ""

echo "⏳ Waiting for RPKI tables to sync to routers (25 seconds)..."
sleep 25

# Show RPKI prefix table from one router to verify
echo "📋 Sample RPKI Prefix Table (R1):"
sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show rpki prefix-table' 2>/dev/null | head -15
echo ""

# Force BGP refresh to ensure RPKI validation is applied
echo "🔄 Forcing BGP soft reconfiguration on all routers..."
for router in "${ROUTERS[@]}"; do
    container="${ROUTER_PREFIX}${router}"
    sudo docker exec "$container" vtysh -c "clear bgp ipv4 unicast * soft" > /dev/null 2>&1 || true
done

echo "⏳ Waiting for BGP to reconverge (15 seconds)..."
sleep 15

echo ""
echo "🎉 Step 5 completed successfully!"
echo "Next step: Run 6-verify-setup.sh"