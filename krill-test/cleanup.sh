#!/bin/bash

# =============================================================================
# Cleanup script for Krill RPKI test environment
# =============================================================================

set -e

echo "🧹 Cleaning up Krill RPKI test environment..."
echo "==========================================="
echo ""

# Destroy the lab
echo "💣 Destroying lab topology..."
sudo containerlab destroy -t krill-test.clab.yml --cleanup

# Clean up any existing RPKI configurations on running routers (if any)
echo "🧹 Cleaning up router RPKI configurations..."
for router in R1 R2 R3 R4 R5 R6 R7; do
    if sudo docker ps --format '{{.Names}}' | grep -q "clab-bgp-anycast-krill-$router"; then
        echo "  Cleaning RPKI config on $router..."
        sudo docker exec "clab-bgp-anycast-krill-$router" vtysh \
            -c "config" \
            -c "no rpki" \
            -c "exit" \
            -c "write memory" > /dev/null 2>&1 || true
    fi
done

# Remove generated files and directories
echo "🗑️  Removing generated files and directories..."

# Remove Krill data
if [ -d "configs/krill" ]; then
    echo "  Removing configs/krill..."
    rm -rf configs/krill
fi

# Remove Routinator data
if [ -d "configs/routinator" ]; then
    echo "  Removing configs/routinator..."
    rm -rf configs/routinator/repository
    rm -f configs/routinator/krill-tal.tal
fi

# Remove router configurations
echo "  Removing router configurations..."
for router in R1 R2 R3 R4 R5 R6 R7; do
    if [ -d "configs/$router" ]; then
        rm -rf "configs/$router"
    fi
done

# Remove lock files
find . -name "*.lock" -type f -delete 2>/dev/null || true

# Verify cleanup
echo "🔍 Verifying cleanup..."
if [ -d "configs/krill" ]; then
    echo "  ⚠️  Warning: configs/krill still exists"
fi

if [ -d "configs/routinator/repository" ]; then
    echo "  ⚠️  Warning: configs/routinator/repository still exists"
fi

echo "✅ Cleanup completed!"
echo ""
echo "To start fresh, run the setup scripts in order:"
echo "  1. ./1-setup-topology.sh"
echo "  2. ./2-init-krill.sh"
echo "  3. ./3-create-roas.sh"
echo "  4. ./4-init-routinator.sh"
echo "  5. ./5-configure-routers.sh"
echo "  6. ./6-verify-setup.sh"