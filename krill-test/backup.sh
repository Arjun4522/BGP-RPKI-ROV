#!/bin/bash
# =============================================================================
# Fixed Router Configuration Script - Version 3
# =============================================================================

# set -e

echo "🔧 Quick Fix: Restarting FRR with RPKI module..."
echo "================================================="
echo ""

# Get Routinator IP
ROUTINATOR_IP=$(sudo docker inspect clab-bgp-anycast-krill-routinator 2>/dev/null | grep -o '"IPAddress": "[0-9.]*' | grep -o '[0-9.]*' | head -1)
if [ -z "$ROUTINATOR_IP" ]; then
    echo "❌ ERROR: Could not find Routinator container IP"
    exit 1
fi
echo "✅ Routinator IP: $ROUTINATOR_IP"
echo ""

echo "🔄 Restarting routers to apply configuration..."

for R in R1 R2 R3 R4 R5 R6 R7; do
    sudo docker restart "clab-bgp-anycast-krill-${R}"
done

echo "⏳ Waiting 60 seconds for BGP to converge..."
sleep 60


ROUTERS=(R1 R2 R3 R4 R5 R6 R7)

for ROUTER in "${ROUTERS[@]}"; do
    CONTAINER="clab-bgp-anycast-krill-${ROUTER}"

    echo "Configuring RPKI on routers...."

    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if sudo docker exec "$CONTAINER" vtysh -c "show bgp summary" > /dev/null 2>&1; then
            BGP_READY=true
            break
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
        echo "     Attempt $RETRY_COUNT/$MAX_RETRIES..."
        sleep 3
    done
    
        echo "   Resetting RPKI config..."
        sudo docker exec "$CONATIANER" vtysh \
        -c "config" \
        -c "no rpki" \
        -c "exit" > /dev/null 2>&1 || true
    
    sleep 2


    # Configure RPKI via vtysh
    echo "   Configuring RPKI..."
    sudo docker exec "$CONTAINER" bash -c "
        vtysh -c 'configure terminal' \
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

echo "⏳ Waiting for RPKI synchronization (40 seconds)..."
sleep 40

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
echo "🎉 Configuration complete!"
echo ""
echo "Quick tests:"
echo "  sudo docker exec -it clab-bgp-anycast-krill-R1 vtysh -c 'show rpki cache-connection'"
echo "  sudo docker exec -it clab-bgp-anycast-krill-R1 vtysh -c 'show rpki prefix-table'"
echo "  sudo docker exec -it clab-bgp-anycast-krill-R1 vtysh -c 'show bgp ipv4 unicast 10.10.10.10/32'"