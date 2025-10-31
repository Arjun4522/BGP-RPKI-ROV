#!/bin/bash

# =============================================================================
# Step 4: Initialize and configure Routinator with Krill local repository
# =============================================================================

set -e

echo "🚀 Step 4: Initializing and configuring Routinator..."
echo "====================================================="
echo ""

# Get container names
ROUTINATOR_CONTAINER=$(sudo docker ps --format '{{.Names}}' | grep routinator)
KRILL_CONTAINER=$(sudo docker ps --format '{{.Names}}' | grep krill-krill)

if [ -z "$ROUTINATOR_CONTAINER" ]; then
    echo "❌ ERROR: Routinator container not found!"
    exit 1
fi

if [ -z "$KRILL_CONTAINER" ]; then
    echo "❌ ERROR: Krill container not found!"
    exit 1
fi

echo "✅ Routinator container: $ROUTINATOR_CONTAINER"
echo "✅ Krill container: $KRILL_CONTAINER"
echo ""

# Stop Routinator if running
echo "🛑 Stopping Routinator..."
sudo docker exec "$ROUTINATOR_CONTAINER" pkill routinator 2>/dev/null || true
sleep 2

# Clean Routinator directories
echo "🧹 Cleaning Routinator directories..."
sudo docker exec "$ROUTINATOR_CONTAINER" sh -c 'rm -rf /root/.rpki-cache/repository/* 2>/dev/null || true'
sudo docker exec "$ROUTINATOR_CONTAINER" sh -c 'rm -rf /root/.rpki-cache/extra-tals/* 2>/dev/null || true'
sudo docker exec "$ROUTINATOR_CONTAINER" mkdir -p /root/.rpki-cache/repository
sudo docker exec "$ROUTINATOR_CONTAINER" mkdir -p /root/.rpki-cache/extra-tals

# Get the Trust Anchor certificate and TAL from Krill's API endpoint
echo "📝 Retrieving Trust Anchor certificate and TAL from Krill..."

# Download the TA certificate from Krill API
sudo docker exec "$KRILL_CONTAINER" wget --no-check-certificate \
    -O /tmp/ta.cer \
    https://127.0.0.1:3000/ta/ta.cer 2>/dev/null

if [ ! -f /tmp/ta.cer ] && ! sudo docker exec "$KRILL_CONTAINER" test -f /tmp/ta.cer; then
    echo "❌ ERROR: Failed to download TA certificate from Krill API"
    echo "   Checking if Krill API is accessible..."
    sudo docker exec "$KRILL_CONTAINER" wget --no-check-certificate -O- https://127.0.0.1:3000/stats 2>&1 | head -5
    exit 1
fi

echo "✅ Trust Anchor certificate downloaded"

# Extract the public key from the TA certificate
echo "🔑 Extracting Trust Anchor public key..."
sudo docker exec "$KRILL_CONTAINER" openssl x509 -in /tmp/ta.cer -pubkey -noout | \
    grep -v "BEGIN PUBLIC KEY" | grep -v "END PUBLIC KEY" > /tmp/ta_pubkey_base64.txt

# Create TAL with rsync URI and public key (RFC 8630 format)
# The TA certificate should be accessible via rsync at the ta_aia location
cat > /tmp/testbed.tal << 'EOF'
rsync://127.0.0.1/ta/ta.cer

EOF

# Append the public key
cat /tmp/ta_pubkey_base64.txt >> /tmp/testbed.tal

# Copy TAL to Routinator
sudo docker cp /tmp/testbed.tal "$ROUTINATOR_CONTAINER":/root/.rpki-cache/extra-tals/testbed.tal

echo "📋 TAL content:"
cat /tmp/testbed.tal
echo ""

# Copy the entire Krill repository to Routinator
echo "📂 Copying RPKI repository from Krill..."
sudo docker exec "$KRILL_CONTAINER" mkdir -p /tmp/repo-copy
sudo docker exec "$KRILL_CONTAINER" sh -c 'cp -r /var/krill/data/repo/rsync/current/* /tmp/repo-copy/'

# Create the directory structure Routinator expects for rsync
sudo docker exec "$ROUTINATOR_CONTAINER" mkdir -p /root/.rpki-cache/repository/rsync/127.0.0.1/repo
sudo docker exec "$ROUTINATOR_CONTAINER" mkdir -p /root/.rpki-cache/repository/rsync/127.0.0.1/ta

# Copy repository from Krill to host
sudo docker cp "$KRILL_CONTAINER":/tmp/repo-copy /tmp/krill-repo-export

# Copy from host to Routinator repository
sudo docker cp /tmp/krill-repo-export/. "$ROUTINATOR_CONTAINER":/root/.rpki-cache/repository/rsync/127.0.0.1/repo/

# Copy TA certificate to host first, then to Routinator
sudo docker cp "$KRILL_CONTAINER":/tmp/ta.cer /tmp/ta.cer.host
sudo docker cp /tmp/ta.cer.host "$ROUTINATOR_CONTAINER":/root/.rpki-cache/repository/rsync/127.0.0.1/ta/ta.cer

# Clean up temporary host file
rm -f /tmp/ta.cer.host

# Clean up
rm -rf /tmp/krill-repo-export /tmp/ta_pubkey_base64.txt /tmp/testbed.tal
sudo docker exec "$KRILL_CONTAINER" rm -rf /tmp/repo-copy /tmp/ta.cer

echo "✅ Repository and TA certificate copied"

# Verify files were copied
echo "📋 Verifying repository structure..."
echo "   TA certificate:"
sudo docker exec "$ROUTINATOR_CONTAINER" ls -lh /root/.rpki-cache/repository/rsync/127.0.0.1/ta/
echo "   ROA files:"
sudo docker exec "$ROUTINATOR_CONTAINER" find /root/.rpki-cache/repository/rsync/127.0.0.1/repo -name "*.roa" | head -5
echo "   Certificate files:"
sudo docker exec "$ROUTINATOR_CONTAINER" find /root/.rpki-cache/repository/rsync/127.0.0.1/repo -name "*.cer" | head -5

# Create Routinator configuration
echo "⚙️  Creating Routinator configuration..."
cat > /tmp/routinator.conf << 'EOF'
# Repository directory
repository-dir = "/root/.rpki-cache/repository"

# Disable bundled RIR TALs (we only want our local testbed)
no-rir-tals = true

# Directory with our custom TAL(s)
extra-tals-dir = "/root/.rpki-cache/extra-tals"

# RTR and HTTP servers
rtr-listen = ["0.0.0.0:3323"]
http-listen = ["0.0.0.0:8323"]

# Disable RRDP since we're using local files only
disable-rrdp = true

# Allow rsync from localhost (required for local testing)
allow-dubious-hosts = true

# Refresh and retry intervals (in seconds)
refresh = 600
retry = 600
expire = 7200

# Logging
log-level = "info"

# Validation mode
stale = "reject"
EOF

sudo docker cp /tmp/routinator.conf "$ROUTINATOR_CONTAINER":/root/.rpki-cache/routinator.conf
rm /tmp/routinator.conf

echo "✅ Configuration created"
echo ""

# Test configuration by running vrps command
echo "🔄 Testing Routinator with configuration..."
VRP_TEST=$(sudo docker exec "$ROUTINATOR_CONTAINER" routinator \
    --config /root/.rpki-cache/routinator.conf \
    vrps --format csv 2>&1)

echo "Test output:"
echo "$VRP_TEST" | head -15
echo ""

# Start Routinator server
echo "🚀 Starting Routinator server..."
sudo docker exec -d "$ROUTINATOR_CONTAINER" routinator \
    --config /root/.rpki-cache/routinator.conf \
    server

# Wait for startup
echo "⏳ Waiting for Routinator to start (20 seconds)..."
sleep 20

# Verify Routinator is running
if sudo docker exec "$ROUTINATOR_CONTAINER" pgrep -f routinator >/dev/null 2>&1; then
    echo "✅ Routinator is running"
else
    echo "⚠️  Routinator may not be running"
    echo "Checking process list:"
    sudo docker exec "$ROUTINATOR_CONTAINER" ps aux | grep routinator || true
fi

echo ""
echo "📋 Checking Routinator VRPs from server..."
sleep 5
VRP_OUTPUT=$(sudo docker exec "$ROUTINATOR_CONTAINER" routinator \
    --config /root/.rpki-cache/routinator.conf \
    vrps --format csv 2>&1 || echo "VRP check failed")

echo "$VRP_OUTPUT" | head -30

if echo "$VRP_OUTPUT" | grep -q "10.10.10.10"; then
    echo ""
    echo "✅ SUCCESS! VRPs found for test prefixes:"
    echo "$VRP_OUTPUT" | grep -E "10.10.10.10|6.6.6.6|7.7.7.7"
    echo ""
    echo "🎉 RPKI validation is working!"
else
    echo ""
    echo "⚠️  VRPs not found yet. Debugging..."
    echo ""
    echo "🔍 Checking TA certificate:"
    sudo docker exec "$ROUTINATOR_CONTAINER" openssl x509 -in /root/.rpki-cache/repository/rsync/127.0.0.1/ta/ta.cer -noout -text | grep -A2 "Subject Key Identifier"
    echo ""
    echo "🔍 TAL file location check:"
    sudo docker exec "$ROUTINATOR_CONTAINER" ls -la /root/.rpki-cache/extra-tals/
    echo ""
    echo "🔍 TAL content:"
    sudo docker exec "$ROUTINATOR_CONTAINER" cat /root/.rpki-cache/extra-tals/testbed.tal | head -10
fi

echo ""
echo "🎉 Step 4 completed!"
echo "Next step: Run 5-configure-routers.sh"