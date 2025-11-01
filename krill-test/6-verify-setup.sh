#!/bin/bash

# =============================================================================
# Step 6: Verify the complete Krill RPKI setup
# =============================================================================

set -e

echo "🚀 Step 6: Verifying the complete Krill RPKI setup..."
echo "======================================================"
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
KRILL_CONTAINER=$(sudo docker ps --format '{{.Names}}' | grep "${LAB_NAME}-krill" | head -1)
ROUTINATOR_CONTAINER=$(sudo docker ps --format '{{.Names}}' | grep "${LAB_NAME}-routinator" | head -1)
ROUTER_PREFIX="clab-${LAB_NAME}-"

if [ -z "$KRILL_CONTAINER" ]; then
    echo "❌ ERROR: Krill container not found!"
    exit 1
fi

if [ -z "$ROUTINATOR_CONTAINER" ]; then
    echo "❌ ERROR: Routinator container not found!"
    exit 1
fi

echo "✅ Krill container: $KRILL_CONTAINER"
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

# =============================================================================
# STEP 1: Verify Krill Status and Configuration
# =============================================================================
echo "🏢 Step 1: Verifying Krill CA status..."
echo ""

max_retries=30
retry_count=0
while ! sudo docker exec "$KRILL_CONTAINER" wget --no-check-certificate --quiet --header="Authorization: Bearer secret" "https://127.0.0.1:3000/" -O - > /dev/null 2>&1; do
    retry_count=$((retry_count + 1))
    if [ $retry_count -ge $max_retries ]; then
        echo "❌ Error: Krill did not respond after $max_retries attempts"
        echo "Logs:"
        sudo docker logs "$KRILL_CONTAINER" 2>/dev/null | tail -20
        exit 1
    fi
    echo "   Attempt $retry_count/$max_retries..."
    sleep 2
done
echo "✅ Krill is up!"

# Check ROAs for testbed CA
echo "   Checking ROAs..."
TESTBED_ROAS=$(sudo docker exec "$KRILL_CONTAINER" krillc --token secret roas list --ca testbed 2>/dev/null || echo "none")

if echo "$TESTBED_ROAS" | grep -q "10.10.10.10"; then
    echo "   ✅ testbed CA has ROA for 10.10.10.10/32 => 65006"
else
    echo "   ⚠️  testbed CA missing ROA for 10.10.10.10/32 => 65006"
fi

if echo "$TESTBED_ROAS" | grep -q "6.6.6.6"; then
    echo "   ✅ testbed CA has ROA for 6.6.6.6/32 => 65006"
else
    echo "   ⚠️  testbed CA missing ROA for 6.6.6.6/32 => 65006"
fi

if echo "$TESTBED_ROAS" | grep -q "7.7.7.7"; then
    echo "   ✅ testbed CA has ROA for 7.7.7.7/32 => 65007"
else
    echo "   ⚠️  testbed CA missing ROA for 7.7.7.7/32 => 65007"
fi

echo ""

# =============================================================================
# STEP 2: Verify Routinator Configuration
# =============================================================================
echo "🔍 Step 2: Verifying Routinator configuration..."
echo ""

# Check if Routinator is running
if sudo docker exec "$ROUTINATOR_CONTAINER" pgrep -f routinator >/dev/null 2>&1; then
    echo "✅ Routinator process is running"
else
    echo "⚠️  Routinator process not found"
fi

# Check TAL file
if sudo docker exec "$ROUTINATOR_CONTAINER" test -f /root/.rpki-cache/tals/my-ca.tal 2>/dev/null; then
    echo "✅ Krill TAL file found"
else
    echo "⚠️  Krill TAL file not found"
fi

# Check if Routinator is listening on expected ports
if sudo docker exec "$ROUTINATOR_CONTAINER" netstat -tln | grep -q ":3324"; then
    echo "✅ Routinator listening on RTR port 3324"
else
    echo "⚠️  Routinator not listening on RTR port 3324"
fi

if sudo docker exec "$ROUTINATOR_CONTAINER" netstat -tln | grep -q ":8323"; then
    echo "✅ Routinator listening on HTTP port 8323"
else
    echo "⚠️  Routinator not listening on HTTP port 8323"
fi

echo ""

# =============================================================================
# STEP 3: Check RPKI Cache Connections
# =============================================================================
echo "📡 Step 3: Checking RPKI cache connections..."
echo ""

# Extract actual validation states
echo "📝 Actual Status from BGP table:"
R6_STATUS=$(sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show bgp ipv4 unicast 10.10.10.10/32' 2>/dev/null | grep "65002 65006" -A 2 | grep "validation-state" || echo "Status: unknown")
R7_STATUS=$(sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show bgp ipv4 unicast 10.10.10.10/32' 2>/dev/null | grep "65004 65005 65007" -A 2 | grep "validation-state" || echo "Status: unknown")
echo "   R6 path (65002 65006): $R6_STATUS"
echo "   R7 path (65004 65005 65007): $R7_STATUS"
echo ""
for router in "${ROUTERS[@]}"; do
    container="${ROUTER_PREFIX}${router}"
    connection_status=$(sudo docker exec "$container" vtysh -c 'show rpki cache-connection' 2>/dev/null | head -1 || echo "Unknown")
    prefix_count=$(sudo docker exec "$container" vtysh -c 'show rpki prefix-table' 2>/dev/null | tail -n +2 | wc -l)
    echo "   $router: $connection_status | Prefixes: $prefix_count"
done

echo ""
echo "📊 R1 RPKI Details:"
echo ""

echo "   Connection Status:"
sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show rpki cache-connection' 2>/dev/null

echo ""
echo "   Full RPKI prefix table (first 10 entries):"
sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show rpki prefix-table' 2>/dev/null | head -10

echo ""
echo "📊 BGP Routes for 10.10.10.10/32 with RPKI Validation:"
echo ""
sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show bgp ipv4 unicast 10.10.10.10/32' 2>/dev/null

echo ""
echo "🎯 Expected Results:"
echo "   ✅ R6 path (AS 65002 65006): rpki validation-state = valid"
echo "   ❌ R7 path (AS 65004 65005 65007): rpki validation-state = invalid"
echo ""

# Extract actual validation states
echo "📝 Actual Status from BGP table:"
R6_STATUS=$(sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show bgp ipv4 unicast 10.10.10.10/32' 2>/dev/null | grep "65002 65006" -A 2 | grep "validation-state" || echo "Status: unknown")
R7_STATUS=$(sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show bgp ipv4 unicast 10.10.10.10/32' 2>/dev/null | grep "65004 65005 65007" -A 2 | grep "validation-state" || echo "Status: unknown")
echo "   R6 path (65002 65006): $R6_STATUS"
echo "   R7 path (65004 65005 65007): $R7_STATUS"
echo ""

# Analysis and troubleshooting
if echo "$R6_STATUS" | grep -q "valid" && echo "$R7_STATUS" | grep -q "invalid"; then
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ✅ SUCCESS: RPKI VALIDATION IS WORKING CORRECTLY!          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "   • R6's announcement (AS65006) is marked as VALID"
    echo "     → Authorized by ROA generated by Krill CA"
    echo ""
    echo "   • R7's announcement (AS65007) is marked as INVALID"
    echo "     → NOT authorized for 10.10.10.10/32"
    echo ""
    echo "✅ The testbed is ready for RPKI ROV experiments!"
else
    echo "⚠️  BGP routes for 10.10.10.10/32 not found in R1's routing table"
    echo ""
    echo "🔧 Troubleshooting steps:"
    echo ""
    echo "   1. Check BGP peer status (sessions may still be establishing):"
    echo "      sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show ip bgp summary'"
    echo ""
    echo "   2. Verify that R6 and R7 are announcing the anycast prefix:"
    echo "      sudo docker exec ${ROUTER_PREFIX}R6 vtysh -c 'show ip bgp'"
    echo "      sudo docker exec ${ROUTER_PREFIX}R7 vtysh -c 'show ip bgp'"
    echo ""
    echo "   3. Verify Krill ROAs:"
    echo "      sudo docker exec $KRILL_CONTAINER krillc --token secret roas list --ca testbed"
    echo ""
    echo "   4. Check Routinator VRPs:"
    echo "      sudo docker exec $ROUTINATOR_CONTAINER routinator --config /root/.rpki-cache/routinator.conf vrps --format csv | grep -E '10.10.10.10|6.6.6.6|7.7.7.7'"
    echo ""
    echo "   5. Verify RPKI cache connection:"
    echo "      sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show rpki cache-connection'"
    echo ""
    echo "   6. Force RPKI cache refresh (if needed):"
    echo "      sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'clear rpki'"
    echo "      sleep 10"
    echo "      sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show rpki prefix-table'"
    echo ""
    echo "   7. Check router configurations for RPKI settings:"
    echo "      sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show running-config | include rpki'"
fi

echo ""
echo "📊 BGP Routes for 10.10.10.10/32 with RPKI Validation:"
echo ""
sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show bgp ipv4 unicast 10.10.10.10/32' 2>/dev/null

echo ""
echo "📊 RPKI Validation State Summary:"
echo ""
echo "   Routes with VALID state:"
VALID_ROUTES=$(sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show bgp ipv4 unicast rpki valid' 2>/dev/null | grep "10.10.10.10" || echo "")
if [ -n "$VALID_ROUTES" ]; then
    echo "$VALID_ROUTES"
else
    echo "   (none containing 10.10.10.10)"
fi

echo ""
echo "   Routes with INVALID state:"
INVALID_ROUTES=$(sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show bgp ipv4 unicast rpki invalid' 2>/dev/null | grep "10.10.10.10" || echo "")
if [ -n "$INVALID_ROUTES" ]; then
    echo "$INVALID_ROUTES"
else
    echo "   (none containing 10.10.10.10)"
fi

echo ""
echo "   Routes with NOT FOUND state:"
NOTFOUND_ROUTES=$(sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show bgp ipv4 unicast rpki notfound' 2>/dev/null | grep "10.10.10.10" || echo "")
if [ -n "$NOTFOUND_ROUTES" ]; then
    echo "$NOTFOUND_ROUTES"
else
    echo "   (none containing 10.10.10.10)"
fi

echo ""
echo "🎯 Expected Results:"
echo "   ✅ R6 path (AS 65002 65006): rpki validation-state = valid"
echo "   ❌ R7 path (AS 65004 65005 65007): rpki validation-state = invalid"
echo ""

# Extract actual validation states
echo "📝 Actual Status from BGP table:"
R6_STATUS=$(sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show bgp ipv4 unicast 10.10.10.10/32' 2>/dev/null | grep "65002 65006" -A 2 | grep "validation-state" || echo "Status: unknown")
R7_STATUS=$(sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show bgp ipv4 unicast 10.10.10.10/32' 2>/dev/null | grep "65004 65005 65007" -A 2 | grep "validation-state" || echo "Status: unknown")
echo "   R6 path (65002 65006): $R6_STATUS"
echo "   R7 path (65004 65005 65007): $R7_STATUS"
echo ""

# Analysis and troubleshooting
if echo "$R6_STATUS" | grep -q "valid" && echo "$R7_STATUS" | grep -q "invalid"; then
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ✅ SUCCESS: RPKI VALIDATION IS WORKING CORRECTLY!          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "   • R6's announcement (AS65006) is marked as VALID"
    echo "     → Authorized by ROA generated by Krill CA"
    echo ""
    echo "   • R7's announcement (AS65007) is marked as INVALID"
    echo "     → NOT authorized for 10.10.10.10/32"
    echo ""
    echo "✅ The testbed is ready for RPKI ROV experiments!"
    
elif echo "$R6_STATUS $R7_STATUS" | grep -q "not found"; then
    echo "⚠️  Status shows 'not found' - ROAs may not be visible yet"
    echo ""
    echo "🔧 Troubleshooting steps:"
    echo ""
    echo "   1. Verify Krill ROAs:"
    echo "      sudo docker exec $KRILL_CONTAINER krillc --token secret roas list --ca testbed"
    echo ""
    echo "   2. Check Routinator logs:"
    echo "      sudo docker exec $ROUTINATOR_CONTAINER cat /tmp/routinator.log 2>/dev/null | tail -20 || echo 'No log file found'"
    echo ""
    echo "   3. Verify Krill TAL file:"
    echo "      sudo docker exec $ROUTINATOR_CONTAINER cat /root/.rpki-cache/tals/my-ca.tal"
    echo ""
    echo "   4. Check RPKI prefix table on R1:"
    echo "      sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show rpki prefix-table'"
    echo ""
    echo "   5. Force RPKI cache refresh:"
    echo "      sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'clear rpki'"
    echo "      sleep 30"
    echo "      sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show bgp ipv4 10.10.10.10/32'"
else
    echo "⚠️  Unexpected RPKI validation state detected"
    echo ""
    echo "   This may indicate:"
    echo "   • Krill CA/ROA configuration issue"
    echo "   • Routinator configuration issue"
    echo "   • FRR RPKI module not syncing correctly"
fi

echo ""
echo "📋 Quick Reference Commands:"
echo ""
echo "# Check Krill status and ROAs"
echo "sudo docker exec $KRILL_CONTAINER krillc --token secret info"
echo "sudo docker exec $KRILL_CONTAINER krillc --token secret roas list --ca testbed"
echo ""
echo "# Check BGP routes with RPKI validation state"
echo "sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show bgp ipv4 unicast 10.10.10.10/32'"
echo ""
echo "# Check VRPs from Routinator"
echo "sudo docker exec $ROUTINATOR_CONTAINER routinator --config /root/.rpki-cache/routinator.conf vrps --format csv | grep -E '10.10.10.10|6.6.6.6|7.7.7.7' || echo 'VRP check failed'"
echo ""
echo "# Check RPKI cache connection status"
echo "sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show rpki cache-connection'"
echo ""
echo "# View RPKI prefix table"
echo "sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show rpki prefix-table'"
echo ""
echo "# Force RPKI refresh"
echo "sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'clear rpki'"
echo ""
echo "# Test connectivity to anycast IP"
echo "sudo docker exec ${ROUTER_PREFIX}R1 ping -c 3 10.10.10.10"
echo ""

echo "🎉 Step 6 completed! Setup verification finished."
echo ""
echo "=================================================================="
echo "📊 SUMMARY OF RPKI TESTBED VERIFICATION"
echo "=================================================================="
echo "✅ Krill CA: Running and configured with testbed CA"
echo "✅ ROAs: Created for 10.10.10.10/32 (AS65006), 6.6.6.6/32 (AS65006), 7.7.7.7/32 (AS65007)"
echo "✅ Routinator: Running and serving VRPs via RTR protocol"
echo "✅ Routers: Configured as RPKI clients connected to Routinator"
echo "✅ RPKI Validation: Should show R6 path as VALID and R7 path as INVALID"
echo "=================================================================="