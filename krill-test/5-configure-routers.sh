#!/bin/bash
# =============================================================================
# Router Configuration Script - No Container Restarts
# =============================================================================

echo "🔧 Router Configuration: Setting up RPKI without restarting containers..."
echo "=========================================================================="
echo ""

# Get Routinator IP
ROUTINATOR_IP=$(sudo docker inspect clab-bgp-anycast-krill-routinator 2>/dev/null | grep -o '"IPAddress": "[0-9.]*' | grep -o '[0-9.]*' | head -1)
if [ -z "$ROUTINATOR_IP" ]; then
    echo "❌ ERROR: Could not find Routinator container IP"
    exit 1
fi
echo "✅ Routinator IP: $ROUTINATOR_IP"
echo ""

# Define routers
ROUTERS=(R1 R2 R3 R4 R5 R6 R7)

# Configure RPKI on each router without restarting
for ROUTER in "${ROUTERS[@]}"; do
    CONTAINER="clab-bgp-anycast-krill-${ROUTER}"
    echo "Configuring RPKI on ${ROUTER}..."
    
    # Check if container is running
    if ! sudo docker ps | grep -q "$CONTAINER"; then
        echo "   ⚠️  ${ROUTER} container not running, skipping..."
        continue
    fi
    
    # Remove existing RPKI config if any
    # echo "   Removing existing RPKI config..."
    # sudo docker exec "$CONTAINER" vtysh \
    #   -c "config" \
    #    -c "no rpki" \
    #    -c "exit" > /dev/null 2>&1 || true
    
    sleep 1

    # Configure RPKI via vtysh
    echo "Configuring RPKI..."
    sudo docker exec "$CONTAINER" bash -c "
        vtysh -c 'configure terminal' \
               -c 'no rpki' \
              -c 'rpki' \
              -c 'rpki cache tcp $ROUTINATOR_IP 3324 preference 1' \
              -c 'rpki polling_period 30' \
              -c 'exit' \
              -c 'exit' > /dev/null 2>&1 && echo 'RPKI config successful' || echo 'RPKI config may have issues'
    "
    
    # Test RPKI connection
    echo "   Testing RPKI connection..."
    sleep 3
    RPKI_OUTPUT=$(sudo docker exec "$CONTAINER" vtysh -c 'show rpki cache-connection' 2>/dev/null || echo "RPKI check failed")
    
    if echo "$RPKI_OUTPUT" | grep -q "Connected"; then
        echo "   ✅ ${ROUTER}: RPKI connected successfully"
    else
        echo "   ⚠️  ${ROUTER}: RPKI not connected yet"
        echo "     Output: $RPKI_OUTPUT"
    fi
    
    echo ""
done

echo "⏳ Waiting for RPKI synchronization (30 seconds)..."
sleep 30

echo ""
echo "📊 Final RPKI Connection Status:"
echo ""

for ROUTER in "${ROUTERS[@]}"; do
    CONTAINER="clab-bgp-anycast-krill-${ROUTER}"
    
    # Check connection
    STATUS=$(sudo docker exec "$CONTAINER" vtysh -c 'show rpki cache-connection' 2>/dev/null | head -2 | tr '\n' ' ' || echo "Unknown")
    PREFIXES=$(sudo docker exec "$CONTAINER" vtysh -c 'show rpki prefix-table' 2>/dev/null | tail -n +2 | wc -l || echo "0")
    
    if echo "$STATUS" | grep -q "Connected"; then
        echo "   ✅ ${ROUTER}: Connected | Prefixes: $PREFIXES"
    else
        echo "   ❌ ${ROUTER}: Not connected | $STATUS"
    fi
done

echo ""
echo "🎉 RPKI configuration complete without disrupting BGP sessions!"
echo ""

echo "🎉 Step 5 completed successfully!"
echo "Next step: Run 6-verify-setup.sh"