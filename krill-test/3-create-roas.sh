#!/bin/bash

# =============================================================================
# Step 4: Create Certificate Authorities and ROAs in Krill
# =============================================================================

set -e

echo "🚀 Step 4: Creating Certificate Authorities and ROAs..."
echo "========================================================"
echo ""

# Get Krill container name
KRILL_CONTAINER=$(sudo docker ps --format '{{.Names}}' | grep krill-krill)
if [ -z "$KRILL_CONTAINER" ]; then
    echo "❌ ERROR: Krill container not found!"
    exit 1
fi
echo "✅ Krill container: $KRILL_CONTAINER"

# Wait for Krill to be ready
echo "⏳ Waiting for Krill to respond..."
max_retries=30
retry_count=0
while ! sudo docker exec "$KRILL_CONTAINER" krillc --token secret info > /dev/null 2>&1; do
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

# Use existing CA
echo "🏢 Using existing CA: testbed"
CA_NAME="testbed"

echo "✅ Certificate Authorities created"
echo ""

# Add ROAs for the anycast scenario
echo "📜 Creating ROAs..."

# Since we're using a single CA, we'll authorize both AS65006 and AS65007 prefixes
# AS65006 is authorized for 10.10.10.10/32 (VALID)
sudo docker exec "$KRILL_CONTAINER" krillc --token secret roas update --ca "$CA_NAME" --add "10.10.10.10/32 => 65006"

# AS65006 is also authorized for its own loopback
sudo docker exec "$KRILL_CONTAINER" krillc --token secret roas update --ca "$CA_NAME" --add "6.6.6.6/32 => 65006"

# AS65007 is authorized for its own loopback (but NOT for 10.10.10.10/32)
sudo docker exec "$KRILL_CONTAINER" krillc --token secret roas update --ca "$CA_NAME" --add "7.7.7.7/32 => 65007"

echo "✅ ROAs created"
echo ""

# List the created ROAs
echo "📋 Listing created ROAs:"
echo ""
sudo docker exec "$KRILL_CONTAINER" krillc --token secret roas list --ca "$CA_NAME"

# Wait for publication and validation
echo ""
echo "⏳ Waiting for ROA publication and validation (30 seconds)..."
sleep 30

echo ""
echo "🎉 Step 4 completed successfully!"
echo "Next step: Run 4-init-routinator.sh"