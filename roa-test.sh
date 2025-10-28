#!/bin/bash
# =============================================================================
# Complete RPKI Setup with Local ROAs - Production Grade
# RFC 8416 SLURM Format - Properly configured for Routinator
# =============================================================================
set -e

MAX_RETRIES=20
RETRY_INTERVAL=3
ROUTINATOR_PORT="3324"  # ← CHANGED: 3323 → 3324 (internal port)

echo "🚀 Complete RPKI Setup with Local ROAs (RFC 8416 SLURM Format)"
echo "================================================================"
echo ""

# =============================================================================
# STEP 0: Auto-detect Lab and Routinator Configuration
# =============================================================================
echo "🔍 Step 0: Auto-detecting lab configuration..."

# Find the containerlab topology file
TOPO_FILE=""
for file in *.clab.yml *.clab.yaml; do
    if [ -f "$file" ]; then
        TOPO_FILE="$file"
        break
    fi
done

if [ -z "$TOPO_FILE" ]; then
    echo "❌ ERROR: No containerlab topology file found!"
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
ROUTINATOR_CONTAINER="clab-${LAB_NAME}-routinator"
ROUTER_PREFIX="clab-${LAB_NAME}-"

# Verify Routinator container exists
if ! sudo docker ps --format '{{.Names}}' | grep -q "^${ROUTINATOR_CONTAINER}$"; then
    echo "❌ ERROR: Routinator container '$ROUTINATOR_CONTAINER' not found!"
    echo "   Available containers:"
    sudo docker ps --format '{{.Names}}' | grep "^clab-" || echo "   (none)"
    echo ""
    echo "   Make sure the lab is deployed: sudo containerlab deploy -t $TOPO_FILE"
    exit 1
fi

# Get Routinator IP address
ROUTINATOR_IP=$(sudo docker inspect "$ROUTINATOR_CONTAINER" 2>/dev/null | grep -o '"IPAddress": "[^"]*' | grep -o '[0-9.]*$' | head -1)

if [ -z "$ROUTINATOR_IP" ]; then
    echo "❌ ERROR: Could not determine IP address for $ROUTINATOR_CONTAINER"
    exit 1
fi

echo "✅ Routinator container: $ROUTINATOR_CONTAINER"
echo "✅ Routinator IP: $ROUTINATOR_IP:$ROUTINATOR_PORT"
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
# STEP 1: Stopping Routinator gracefully
# =============================================================================
echo "Stopping Routinator gracefully..."
# SIGTERM → SIGKILL on the child process
sudo docker exec "$ROUTINATOR_CONTAINER" pkill -15 routinator 2>/dev/null || true
sleep 2

# Force-kill the child if still alive
sudo docker exec "$ROUTINATOR_CONTAINER" pkill -9 routinator 2>/dev/null || true
sleep 2

# Final sanity check
if sudo docker exec "$ROUTINATOR_CONTAINER" pgrep -f routinator >/dev/null 2>&1; then
    echo "WARNING: Routinator still running – final killall"
    sudo docker exec "$ROUTINATOR_CONTAINER" killall -9 routinator 2>/dev/null || true
    sleep 2
fi

echo "Routinator stopped"
echo ""

# =============================================================================
# STEP 2: Create SLURM Exceptions File (RFC 8416 Format)
# =============================================================================
echo "📋 Step 2: Creating SLURM local exceptions file (RFC 8416)..."
sudo docker exec "$ROUTINATOR_CONTAINER" sh -c 'cat > /root/.rpki-cache/local-exceptions.json << "EOF"
{
  "slurmVersion": 1,
  "validationOutputFilters": {
    "prefixFilters": [],
    "bgpsecFilters": []
  },
  "locallyAddedAssertions": {
    "prefixAssertions": [
      {
        "asn": 65006,
        "prefix": "10.10.10.10/32",
        "maxPrefixLength": 32,
        "comment": "Anycast server R6 - Valid path"
      },
      {
        "asn": 65006,
        "prefix": "6.6.6.6/32",
        "maxPrefixLength": 32,
        "comment": "R6 loopback"
      },
      {
        "asn": 65007,
        "prefix": "7.7.7.7/32",
        "maxPrefixLength": 32,
        "comment": "R7 loopback (NOT authorized for 10.10.10.10/32)"
      }
    ],
    "bgpsecAssertions": []
  }
}
EOF'

echo "✅ SLURM exceptions file created"
echo ""
echo "📄 Content:"
sudo docker exec "$ROUTINATOR_CONTAINER" cat /root/.rpki-cache/local-exceptions.json
echo ""

# Validate JSON format
echo "🔍 Validating JSON format..."
if sudo docker exec "$ROUTINATOR_CONTAINER" sh -c 'command -v python3 >/dev/null 2>&1'; then
    if sudo docker exec "$ROUTINATOR_CONTAINER" python3 -m json.tool /root/.rpki-cache/local-exceptions.json >/dev/null 2>&1; then
        echo "✅ JSON format is valid"
    else
        echo "❌ WARNING: JSON format may be invalid"
    fi
else
    echo "⚠️  Python3 not available, skipping JSON validation"
fi
echo ""

# =============================================================================
# STEP 3: Create/Update Routinator Configuration File
# =============================================================================
echo "🔧 Step 3: Creating Routinator configuration file..."
sudo docker exec "$ROUTINATOR_CONTAINER" sh -c 'cat > /root/.rpki-cache/routinator.conf << "EOF"
# RPKI cache directory
repository-dir = "/root/.rpki-cache/repository"

# Local exceptions file (RFC 8416 SLURM format)
exceptions = ["/root/.rpki-cache/local-exceptions.json"]

# RTR server configuration
rtr-listen = ["0.0.0.0:3324"]  # ← CHANGED: 3323 → 3324

# HTTP server configuration
http-listen = ["0.0.0.0:8323", "0.0.0.0:9556"]

# Logging level
log-level = "info"

# Validation refresh interval (seconds)
refresh = 600

# Retry interval for failed fetches
retry = 600

# Expiry time for stale data
expire = 7200

# Stale object handling
stale = "reject"
EOF'

echo "✅ Configuration file created"
echo ""


# =============================================================================
# STEP 4: Start Routinator with SLURM configuration
# =============================================================================
echo "Step 4: Starting Routinator with SLURM configuration..."

# Start Routinator with config on internal port 3324
sudo docker exec -d "$ROUTINATOR_CONTAINER" \
  routinator --config /root/.rpki-cache/routinator.conf server \
  > /tmp/routinator.log 2>&1

echo "Waiting for Routinator to start (15 seconds)..."
sleep 15

# -----------------------------------------------------------------
# Port-readiness loop
# -----------------------------------------------------------------
echo "Verifying Routinator is listening on port $ROUTINATOR_PORT..."
retry_count=0
routinator_started=false
while [ $retry_count -lt $MAX_RETRIES ]; do
    if sudo docker exec "$ROUTINATOR_CONTAINER" netstat -tln 2>/dev/null | grep -q ":$ROUTINATOR_PORT"; then
        echo "Routinator is listening on port $ROUTINATOR_PORT!"
        routinator_started=true
        break
    fi
    retry_count=$((retry_count + 1))
    echo " Attempt $retry_count/$MAX_RETRIES..."
    sleep $RETRY_INTERVAL
done

if [ "$routinator_started" = false ]; then
    echo "ERROR: Routinator failed to start on port $ROUTINATOR_PORT"
    echo ""
    echo "Routinator logs:"
    sudo docker exec "$ROUTINATOR_CONTAINER" cat /tmp/routinator.log 2>/dev/null || echo "No logs available"
    echo ""
    echo "Port status:"
    sudo docker exec "$ROUTINATOR_CONTAINER" netstat -tln 2>/dev/null | grep 3324 || echo "Port 3324 not listening"
    echo ""
    echo "Process status:"
    sudo docker exec "$ROUTINATOR_CONTAINER" ps aux | grep routinator || echo "No routinator process found"
    exit 1
fi

echo ""
echo "Routinator process status:"
sudo docker exec "$ROUTINATOR_CONTAINER" ps aux | grep -v grep | grep routinator || echo "Process list not available"
echo ""

echo "Waiting for RPKI data and SLURM exceptions to load (25 seconds)..."
sleep 25


# =============================================================================
# STEP 5: Verify Local ROAs are Loaded
# =============================================================================
echo ""
echo "Step 5: Verifying local ROAs are loaded..."
echo ""
echo "Testing VRPs for our test prefixes:"

# Check Routinator logs for SLURM loading
echo ""
echo "Checking if SLURM exceptions were loaded:"
if sudo docker exec "$ROUTINATOR_CONTAINER" cat /tmp/routinator.log 2>/dev/null | grep -i -E "slurm|exception|local-exceptions" | tail -5; then
    echo "SLURM file loaded successfully"
else
    echo "No SLURM-related log entries found"
fi

# Test VRP queries with --config and timeout
echo ""
echo "Querying VRPs from Routinator..."
if timeout 30 sudo docker exec "$ROUTINATOR_CONTAINER" \
  routinator --config /root/.rpki-cache/routinator.conf vrps --format csv 2>/dev/null | grep -q "10.10.10.10"; then

    echo "Found 10.10.10.10/32 in VRPs:"
    sudo docker exec "$ROUTINATOR_CONTAINER" \
      routinator --config /root/.rpki-cache/routinator.conf vrps --format csv 2>/dev/null | grep "10.10.10.10"

    echo ""
    echo "SUCCESS: Local ROA for 10.10.10.10/32 (AS65006) is properly loaded!"

else
    echo "10.10.10.10/32 NOT found in VRPs!"
    echo ""
    echo "Checking for other test prefixes:"
    sudo docker exec "$ROUTINATOR_CONTAINER" \
      routinator --config /root/.rpki-cache/routinator.conf vrps --format csv 2>/dev/null | \
      grep -E "6\.6\.6\.6|7\.7\.7\.7" || echo " No test prefixes (6.6.6.6 or 7.7.7.7) found"

    echo ""
    echo "WARNING: Local ROAs may not be loaded. Check:"
    echo "  • SLURM file: /root/.rpki-cache/local-exceptions.json"
    echo "  • Config: exceptions = [\"/root/.rpki-cache/local-exceptions.json\"]"
    echo "  • Routinator logs: cat /tmp/routinator.log"
fi

echo ""
echo "Total VRP count:"
VRP_COUNT=$(sudo docker exec "$ROUTINATOR_CONTAINER" \
  routinator --config /root/.rpki-cache/routinator.conf vrps --format csv 2>/dev/null | wc -l || echo "0")
echo " Total VRPs loaded: $VRP_COUNT"

# Additional verification via HTTP API
echo ""
echo "Verifying via HTTP API (port 9556):"
sleep 2
if curl -s --max-time 5 "http://${ROUTINATOR_IP}:9556/api/v1/validity/65006/10.10.10.10/32" 2>/dev/null | grep -q "valid"; then
    echo "HTTP API confirms: 10.10.10.10/32 → AS65006 is VALID"
elif curl -s --max-time 5 "http://${ROUTINATOR_IP}:9556/metrics" 2>/dev/null | grep -q "routinator"; then
    echo "HTTP API is up and responding"
else
    echo "HTTP API check inconclusive or unreachable"
fi
echo ""

# =============================================================================
# STEP 6: Configure RPKI on All Routers
# =============================================================================
echo "📡 Step 6: Configuring RPKI on all routers..."
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
    
    # Configure RPKI with TCP connection (routers use external port 3323)
    sudo docker exec "$container" vtysh \
        -c "config" \
        -c "rpki" \
        -c "rpki cache tcp $ROUTINATOR_IP 3324 preference 1" \  # ← KEEP 3323 (external port)
        -c "rpki polling_period 30" \
        -c "exit" \
        -c "exit" \
        -c "write memory" > /dev/null 2>&1
    
    # Verify connection with retries
    local connected=false
    for i in {1..12}; do
        sleep 3
        if sudo docker exec "$container" vtysh -c 'show rpki cache-connection' 2>/dev/null | grep -q "Connected"; then
            echo "      ✅ $router connected to RPKI cache"
            connected=true
            break
        fi
        [ $i -lt 12 ] && echo "      ⏳ $router connection attempt $i/12..."
    done
    
    if [ "$connected" = false ]; then
        echo "      ⚠️  $router failed to connect to RPKI cache"
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
fi
echo ""

echo "⏳ Waiting for RPKI tables to sync to routers (25 seconds)..."
sleep 25

# Force BGP refresh to ensure RPKI validation is applied
echo "🔄 Forcing BGP soft reconfiguration on all routers..."
for router in "${ROUTERS[@]}"; do
    container="${ROUTER_PREFIX}${router}"
    sudo docker exec "$container" vtysh -c "clear bgp ipv4 unicast * soft" > /dev/null 2>&1 || true
done

echo "⏳ Waiting for BGP to reconverge (15 seconds)..."
sleep 15

# =============================================================================
# STEP 7: Comprehensive Verification
# =============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "🔍 COMPREHENSIVE VERIFICATION"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check all routers connection status
echo "📊 Router RPKI Connection Status:"
echo ""
for router in "${ROUTERS[@]}"; do
    container="${ROUTER_PREFIX}${router}"
    connection_status=$(sudo docker exec "$container" vtysh -c 'show rpki cache-connection' 2>/dev/null | head -1 || echo "Unknown")
    prefix_count=$(sudo docker exec "$container" vtysh -c 'show rpki prefix-table' 2>/dev/null | tail -n +2 | wc -l)
    echo "   $router: $connection_status | Prefixes: $prefix_count"
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "📊 R1 RPKI Details"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "   Connection Status:"
sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show rpki cache-connection' 2>/dev/null

echo ""
echo "   Searching for 10.10.10.10/32 in RPKI prefix table:"
if sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show rpki prefix 10.10.10.10/32' 2>/dev/null | grep -q "10.10.10.10"; then
    sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show rpki prefix 10.10.10.10/32' 2>/dev/null
    echo ""
    echo "✅ Prefix found in RPKI table"
else
    echo "   ⚠️  10.10.10.10/32 not found in RPKI prefix table"
    echo ""
    echo "   Checking for related prefixes (6.6.6.6, 7.7.7.7):"
    sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show rpki prefix-table' 2>/dev/null | grep -E "6.6.6.6|7.7.7.7" | head -5 || echo "   Not found"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "📊 BGP Routes for 10.10.10.10/32 with RPKI Validation"
echo "═══════════════════════════════════════════════════════════════"
echo ""
sudo docker exec "${ROUTER_PREFIX}R1" vtysh -c 'show bgp ipv4 unicast 10.10.10.10/32' 2>/dev/null

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "📊 RPKI Validation State Summary"
echo "═══════════════════════════════════════════════════════════════"
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
echo "═══════════════════════════════════════════════════════════════"
echo "✨ RPKI Setup Complete!"
echo "═══════════════════════════════════════════════════════════════"
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
    echo "     → Authorized by ROA in SLURM exceptions"
    echo ""
    echo "   • R7's announcement (AS65007) is marked as INVALID"
    echo "     → NOT authorized for 10.10.10.10/32"
    echo ""
    echo "✅ The testbed is ready for RPKI ROV experiments!"
    
elif echo "$R6_STATUS $R7_STATUS" | grep -q "not found"; then
    echo "⚠️  Status shows 'not found' - Local ROAs may not be visible yet"
    echo ""
    echo "🔧 Troubleshooting steps:"
    echo ""
    echo "   1. Verify Routinator loaded the SLURM exceptions:"
    echo "      sudo docker exec $ROUTINATOR_CONTAINER routinator -c /root/.rpki-cache/routinator.conf vrps --format csv | grep 10.10.10.10"
    echo ""
    echo "   2. Check Routinator logs for SLURM loading:"
    echo "      sudo docker exec $ROUTINATOR_CONTAINER cat /tmp/routinator.log | grep -i 'exception\|slurm'"
    echo ""
    echo "   3. Verify SLURM file format:"
    echo "      sudo docker exec $ROUTINATOR_CONTAINER cat /root/.rpki-cache/local-exceptions.json"
    echo ""
    echo "   4. Check RPKI prefix table on R1:"
    echo "      sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show rpki prefix-table' | grep -E '10.10.10.10|6.6.6.6|7.7.7.7'"
    echo ""
    echo "   5. Force RPKI cache refresh:"
    echo "      sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'rpki reset'"
    echo "      sleep 30"
    echo "      sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show bgp ipv4 10.10.10.10/32'"
    echo ""
    echo "   6. Restart Routinator if needed:"
    echo "      sudo docker exec $ROUTINATOR_CONTAINER pkill routinator"
    echo "      sudo docker exec -d $ROUTINATOR_CONTAINER routinator -c /root/.rpki-cache/routinator.conf server"
    echo "      sleep 30"
    echo "      sudo ./roa.sh"
else
    echo "⚠️  Unexpected RPKI validation state detected"
    echo ""
    echo "   This may indicate:"
    echo "   • SLURM exceptions not loaded properly"
    echo "   • Routinator configuration issue"
    echo "   • FRR RPKI module not syncing correctly"
    echo ""
    echo "   Review the troubleshooting steps above"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "📋 Quick Reference Commands"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "# Check BGP routes with RPKI validation state"
echo "sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show bgp ipv4 unicast 10.10.10.10/32'"
echo ""
echo "# Verify VRPs from Routinator (should include 10.10.10.10)"
echo "sudo docker exec $ROUTINATOR_CONTAINER routinator -c /root/.rpki-cache/routinator.conf vrps --format csv | grep 10.10.10.10"
echo ""
echo "# Check RPKI cache connection status"
echo "sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show rpki cache-connection'"
echo ""
echo "# View RPKI prefix table"
echo "sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show rpki prefix-table' | grep -E '10.10.10.10|6.6.6.6|7.7.7.7'"
echo ""
echo "# Check routes by validation state"
echo "sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show bgp ipv4 unicast rpki valid'"
echo "sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show bgp ipv4 unicast rpki invalid'"
echo "sudo docker exec ${ROUTER_PREFIX}R1 vtysh -c 'show bgp ipv4 unicast rpki notfound'"
echo ""
echo "# Test connectivity to anycast IP"
echo "sudo docker exec ${ROUTER_PREFIX}R1 ping -c 3 10.10.10.10"
echo ""
echo "# View Routinator logs"
echo "sudo docker exec $ROUTINATOR_CONTAINER cat /tmp/routinator.log | tail -50"
echo ""

echo "═══════════════════════════════════════════════════════════════"
echo "🧪 Advanced Testing: Apply RPKI-based Route Filtering"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "To drop INVALID routes (enforce ROV):"
echo ""
echo "sudo docker exec -it ${ROUTER_PREFIX}R1 vtysh << 'EOFVTYSH'"
echo "configure terminal"
echo "!"
echo "route-map RPKI-FILTER permit 10"
echo " match rpki valid"
echo "!"
echo "route-map RPKI-FILTER permit 15"
echo " match rpki notfound"
echo "!"
echo "route-map RPKI-FILTER deny 20"
echo " match rpki invalid"
echo "!"
echo "router bgp 65001"
echo " address-family ipv4 unicast"
echo "  neighbor 10.0.12.2 route-map RPKI-FILTER in"
echo "  neighbor 10.0.14.4 route-map RPKI-FILTER in"
echo " exit-address-family"
echo "!"
echo "end"
echo "clear bgp ipv4 unicast * soft"
echo "EOFVTYSH"
echo ""
echo "After applying, only VALID routes will be accepted!"
echo ""
