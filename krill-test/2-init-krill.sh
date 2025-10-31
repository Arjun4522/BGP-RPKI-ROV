#!/bin/bash
# =============================================================================
# Step 2: Initialize and configure Krill CA
# =============================================================================
set -e
echo "🚀 Step 2: Initializing and configuring Krill CA..."
echo "==================================================="
echo ""

# Deploy the lab
echo "🔧 Deploying lab topology..."
sudo containerlab deploy -t krill-test.clab.yml
echo ""

echo "⏳ Waiting for containers to start (30 seconds)..."
for i in {1..30}; do
    echo -n "."
    sleep 1
done
echo ""
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

# Initialize publication server
# echo "📋 Initializing Publication Server..."
# sudo docker exec "$KRILL_CONTAINER" krillc --token secret pubserver server init \
#    --rrdp https://127.0.0.1:3001/rrdp/ \
#    --rsync rsync://127.0.0.1/repo/ || echo "Publication server already initialized"

# Set up testbed CA publisher
# echo "📡 Setting up testbed CA publisher..."
# sudo docker exec "$KRILL_CONTAINER" bash -c "krillc --token secret repo request --ca testbed > /tmp/publisher-request.xml" || echo "Repository request already exists"
# sudo docker exec "$KRILL_CONTAINER" bash -c "krillc --token secret pubserver publishers add --request /tmp/publisher-request.xml > /tmp/repository-response.xml" || echo "Publisher already added"
# sudo docker exec "$KRILL_CONTAINER" bash -c "krillc --token secret repo configure --ca testbed --response /tmp/repository-response.xml" || echo "Repository already configured"

mkdir -p ./configs/routinator/tals

# Get the TAL from the Trust Anchor endpoint
echo "📂 Exporting TAL file from testbed Trust Anchor..."

echo "Wait 10 secs"
sleep 10  # Wait for TA to be ready

sudo docker exec "$KRILL_CONTAINER" krillc --token secret repo show --ca testbed > ./configs/routinator/tals/my-ca.tal

echo "📋 Testbed TAL content:"
cat ./configs/routinator/tals/my-ca.tal
echo ""

echo "✅ Setup complete! You can now create ROAs under 'testbed' CA"

# Summarize info
sudo docker exec clab-bgp-anycast-krill-krill krillc --token secret list
sudo docker exec clab-bgp-anycast-krill-krill krillc --token secret show --ca testbed

