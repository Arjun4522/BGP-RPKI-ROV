#!/bin/bash

# =============================================================================
# BGP Anycast + RPKI ROV Testbed with Krill CA
# Containerlab + FRR + Krill + Routinator
# =============================================================================
# Anycast IP : 10.10.10.10/32
# ROA Status : AS65006 → VALID   (R6 - Short Path)
#            : AS65007 → INVALID (R7 - Long Path)
# =============================================================================

set -e

echo "🚀 Setting up BGP Anycast + RPKI Testbed with Krill..."
echo "======================================================="
echo ""

# Create directory structure
echo "📁 Creating directory structure..."
mkdir -p configs/{R1,R2,R3,R4,R5,R6,R7,routinator,krill}

# Create Krill configuration
echo "🔧 Creating Krill configuration..."
cat > configs/krill/krill.conf << 'KRILL_CONF'
# Basic logging
log_level = "Info"

# Admin token for API access (CHANGE IN PRODUCTION)
admin_token = "secret"

# HTTP listener
http_listen = "0.0.0.0:3000"

# Data directory
data_dir = "/var/krill/data"

# Repository where Krill will publish
[repository]
type = "embedded"
contact = "embedded@example.net"

# CA configuration
[ca]
# Enable RFC 6487 compliant resource certificates
allow_rfc_6487_skif = true

# Publication server configuration
[publication]
type = "embedded"

# Configure RRDP for publication
[rrdp]
base_uri = "https://krill.example.net/rrdp/"
notification_uri = "https://krill.example.net/rrdp/notification.xml"
bind_address = "0.0.0.0:3001"

# Configure rsync for publication
[rsync]
base_uri = "rsync://krill.example.net/repo/"

KRILL_CONF

echo "✅ Krill configuration created"
echo ""

# Create Routinator configuration file
echo "📝 Creating Routinator configuration..."
cat > configs/routinator/routinator.conf << 'ROUTINATOR_CONF'
# RPKI cache directory
repository-dir = "/root/.rpki-cache/repository"

# RTR server configuration
rtr-listen = ["0.0.0.0:3324"]

# HTTP server configuration  
http-listen = ["0.0.0.0:8323"]

# Trust anchor locator for Krill
# This will be updated after Krill is running
tal-files = ["/root/.rpki-cache/krill-tal.tal"]

# Validation refresh interval (seconds)
refresh = 600

# Stale object handling
stale = "reject"
ROUTINATOR_CONF

echo "✅ Routinator configuration created"
echo ""

# Create daemons file for all routers with RPKI support
echo "⚙️  Generating FRR configurations with RPKI support..."
for router in R1 R2 R3 R4 R5 R6 R7; do
    cat > configs/${router}/daemons << 'DAEMONS'
bgpd=yes
zebra=yes
staticd=no
ospfd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no
fabricd=no

vtysh_enable=yes
zebra_options=" -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1 -M rpki"
DAEMONS
done

# Create vtysh.conf for all routers
for router in R1 R2 R3 R4 R5 R6 R7; do
    cat > configs/${router}/vtysh.conf << 'VTYSH'
service integrated-vtysh-config
VTYSH
done

echo "✅ Base configuration files created with RPKI module enabled"
echo ""

# R1 Configuration - Core Router with RPKI
echo "🔧 Configuring R1 (Core Router + RPKI Client)..."
cat > configs/R1/frr.conf << 'R1_CONFIG'
frr version 10.2.1_git
frr defaults traditional
hostname R1
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
interface eth1
 ip address 10.0.12.1/24
!
interface eth2
 ip address 10.0.14.1/24
!
interface lo
 ip address 1.1.1.1/32
!
rpki
 rpki cache 172.20.30.7 3323 preference 1
 rpki polling_period 30
!
router bgp 65001
 bgp router-id 1.1.1.1
 no bgp ebgp-requires-policy
 no bgp enforce-first-as
 neighbor 10.0.12.2 remote-as 65002
 neighbor 10.0.14.4 remote-as 65004
 !
 address-family ipv4 unicast
  redistribute connected
  neighbor 10.0.12.2 next-hop-self
  neighbor 10.0.14.4 next-hop-self
 exit-address-family
!
line vty
!
R1_CONFIG

# R2 Configuration - Short Path Router with RPKI
echo "🔧 Configuring R2 (Short Path + RPKI Client)..."
cat > configs/R2/frr.conf << 'R2_CONFIG'
frr version 10.2.1_git
frr defaults traditional
hostname R2
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
interface eth1
 ip address 10.0.12.2/24
!
interface eth2
 ip address 10.0.23.2/24
!
interface eth3
 ip address 10.0.26.2/24
!
interface lo
 ip address 2.2.2.2/32
!
rpki
 rpki cache 172.20.30.7 3323 preference 1
 rpki polling_period 30
!
router bgp 65002
 bgp router-id 2.2.2.2
 no bgp ebgp-requires-policy
 no bgp enforce-first-as
 neighbor 10.0.12.1 remote-as 65001
 neighbor 10.0.23.3 remote-as 65003
 neighbor 10.0.26.6 remote-as 65006
 !
 address-family ipv4 unicast
  neighbor 10.0.12.1 next-hop-self
  neighbor 10.0.23.3 next-hop-self
  neighbor 10.0.26.6 next-hop-self
  redistribute connected
 exit-address-family
!
line vty
!
R2_CONFIG

# R3 Configuration - Destination Router
echo "🔧 Configuring R3 (Destination Router)..."
cat > configs/R3/frr.conf << 'R3_CONFIG'
frr version 10.2.1_git
frr defaults traditional
hostname R3
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
interface eth1
 ip address 10.0.23.3/24
!
interface eth2
 ip address 10.0.53.3/24
!
interface lo
 ip address 3.3.3.3/32
!
rpki
 rpki cache 172.20.30.7 3323 preference 1
 rpki polling_period 30
!
router bgp 65003
 bgp router-id 3.3.3.3
 no bgp ebgp-requires-policy
 no bgp enforce-first-as
 neighbor 10.0.23.2 remote-as 65002
 neighbor 10.0.53.5 remote-as 65005
 !
 address-family ipv4 unicast
  redistribute connected
  neighbor 10.0.23.2 next-hop-self
  neighbor 10.0.53.5 next-hop-self
 exit-address-family
!
line vty
!
R3_CONFIG

# R4 Configuration - Long Path First Hop
echo "🔧 Configuring R4 (Long Path Router + RPKI)..."
cat > configs/R4/frr.conf << 'R4_CONFIG'
frr version 10.2.1_git
frr defaults traditional
hostname R4
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
interface eth1
 ip address 10.0.14.4/24
!
interface eth2
 ip address 10.0.45.4/24
!
interface lo
 ip address 4.4.4.4/32
!
rpki
 rpki cache 172.20.30.7 3323 preference 1
 rpki polling_period 30
!
router bgp 65004
 bgp router-id 4.4.4.4
 no bgp ebgp-requires-policy
 no bgp enforce-first-as
 neighbor 10.0.14.1 remote-as 65001
 neighbor 10.0.45.5 remote-as 65005
 !
 address-family ipv4 unicast
  neighbor 10.0.14.1 next-hop-self
  neighbor 10.0.45.5 next-hop-self
  redistribute connected
 exit-address-family
!
line vty
!
R4_CONFIG

# R5 Configuration - Long Path Second Hop with RPKI
echo "🔧 Configuring R5 (Long Path + RPKI Client)..."
cat > configs/R5/frr.conf << 'R5_CONFIG'
frr version 10.2.1_git
frr defaults traditional
hostname R5
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
interface eth1
 ip address 10.0.45.5/24
!
interface eth2
 ip address 10.0.53.5/24
!
interface eth3
 ip address 10.0.57.5/24
!
interface lo
 ip address 5.5.5.5/32
!
rpki
 rpki cache 172.20.30.7 3323 preference 1
 rpki polling_period 30
!
router bgp 65005
 bgp router-id 5.5.5.5
 no bgp ebgp-requires-policy
 no bgp enforce-first-as
 neighbor 10.0.45.4 remote-as 65004
 neighbor 10.0.53.3 remote-as 65003
 neighbor 10.0.57.7 remote-as 65007
 !
 address-family ipv4 unicast
  neighbor 10.0.45.4 next-hop-self
  neighbor 10.0.53.3 next-hop-self
  neighbor 10.0.57.7 next-hop-self
  redistribute connected
 exit-address-family
!
line vty
!
R5_CONFIG

# R6 Configuration - Anycast Server 1 (VALID via RPKI)
echo "🔧 Configuring R6 (Anycast Server 1 - RPKI VALID)..."
cat > configs/R6/frr.conf << 'R6_CONFIG'
frr version 10.2.1_git
frr defaults traditional
hostname R6
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
interface eth1
 ip address 10.0.26.6/24
!
interface lo
 ip address 6.6.6.6/32
 ip address 10.10.10.10/32
!
rpki
 rpki cache 172.20.30.7 3323 preference 1
 rpki polling_period 30
!
router bgp 65006
 bgp router-id 6.6.6.6
 no bgp ebgp-requires-policy
 no bgp enforce-first-as
 neighbor 10.0.26.2 remote-as 65002
 !
 address-family ipv4 unicast
  network 10.10.10.10/32
  network 6.6.6.6/32
  neighbor 10.0.26.2 route-map SET-LOCAL-PREF out
 exit-address-family
!
route-map SET-LOCAL-PREF permit 10
 set local-preference 200
!
line vty
!
R6_CONFIG

# R7 Configuration - Anycast Server 2 (INVALID via RPKI)
echo "🔧 Configuring R7 (Anycast Server 2 - RPKI INVALID)..."
cat > configs/R7/frr.conf << 'R7_CONFIG'
frr version 10.2.1_git
frr defaults traditional
hostname R7
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
interface eth1
 ip address 10.0.57.7/24
!
interface lo
 ip address 7.7.7.7/32
 ip address 10.10.10.10/32
!
rpki
 rpki cache 172.20.30.7 3323 preference 1
 rpki polling_period 30
!
router bgp 65007
 bgp router-id 7.7.7.7
 no bgp ebgp-requires-policy
 no bgp enforce-first-as
 neighbor 10.0.57.5 remote-as 65005
 !
 address-family ipv4 unicast
  network 10.10.10.10/32
  network 7.7.7.7/32
  neighbor 10.0.57.5 route-map SET-LOCAL-PREF out
 exit-address-family
!
route-map SET-LOCAL-PREF permit 10
 set local-preference 200
!
line vty
!
R7_CONFIG

echo "✅ All router configurations with RPKI support created"
echo ""

# Create the containerlab topology file with Krill and Routinator
echo "📋 Creating containerlab topology with Krill and RPKI..."
cat > krill-test.clab.yml << 'TOPOLOGY'
name: bgp-anycast-krill

topology:
  nodes:
    krill:
      kind: linux
      image: nlnetlabs/krill:latest
      user: root
      ports:
        - "3000:3000"
        - "3001:3001"
      env:
        KRILL_AUTH_TOKEN: secret
      cmd: |
        sh -c '
        mkdir -p /var/krill/data
        # Create initial Krill config if it doesnt exist
        if [ ! -f /etc/krill/krill.conf ]; then
          mkdir -p /etc/krill
          cat > /etc/krill/krill.conf << EOF
        log_level = "Info"
        admin_token = "secret"
        http_listen = "0.0.0.0:3000"
        data_dir = "/var/krill/data"
        
        [repository]
        type = "embedded"
        contact = "embedded@example.net"
        
        [ca]
        allow_rfc_6487_skif = true
        
        [publication]
        type = "embedded"
        
        [rrdp]
        base_uri = "https://krill.example.net/rrdp/"
        notification_uri = "https://krill.example.net/rrdp/notification.xml"
        bind_address = "0.0.0.0:3001"
        
        [rsync]
        base_uri = "rsync://krill.example.net/repo/"
        EOF
        fi
        krill -c /etc/krill/krill.conf
        '

    routinator:
      kind: linux
      image: nlnetlabs/routinator:latest
      user: root
      ports:
        - "3323:3324"
        - "8323:8323"
      entrypoint: 
      cmd: |
        sh -c "
        # Wait for Krill to be ready
        sleep 10
        # Start Routinator
        routinator --config /root/.rpki-cache/routinator.conf server
        "
      binds:
        - ./configs/routinator:/root/.rpki-cache

    R1:
      kind: linux
      image: quay.io/frrouting/frr:10.2.1
      binds:
        - ./configs/R1:/etc/frr
      exec:
        - ip addr replace 10.0.12.1/24 dev eth1
        - ip addr replace 10.0.14.1/24 dev eth2
        - ip addr replace 1.1.1.1/32 dev lo
        
    R2:
      kind: linux
      image: quay.io/frrouting/frr:10.2.1
      binds:
        - ./configs/R2:/etc/frr
      exec:
        - ip addr replace 10.0.12.2/24 dev eth1
        - ip addr replace 10.0.23.2/24 dev eth2
        - ip addr replace 10.0.26.2/24 dev eth3
        - ip addr replace 2.2.2.2/32 dev lo
        
    R3:
      kind: linux
      image: quay.io/frrouting/frr:10.2.1
      binds:
        - ./configs/R3:/etc/frr
      exec:
        - ip addr replace 10.0.23.3/24 dev eth1
        - ip addr replace 10.0.53.3/24 dev eth2
        - ip addr replace 3.3.3.3/32 dev lo

    R4:
      kind: linux
      image: quay.io/frrouting/frr:10.2.1
      binds:
        - ./configs/R4:/etc/frr
      exec:
        - ip addr replace 10.0.14.4/24 dev eth1
        - ip addr replace 10.0.45.4/24 dev eth2
        - ip addr replace 4.4.4.4/32 dev lo

    R5:
      kind: linux
      image: quay.io/frrouting/frr:10.2.1
      binds:
        - ./configs/R5:/etc/frr
      exec:
        - ip addr replace 10.0.45.5/24 dev eth1
        - ip addr replace 10.0.53.5/24 dev eth2
        - ip addr replace 10.0.57.5/24 dev eth3
        - ip addr replace 5.5.5.5/32 dev lo

    R6:
      kind: linux
      image: quay.io/frrouting/frr:10.2.1
      binds:
        - ./configs/R6:/etc/frr
      exec:
        - ip addr replace 10.0.26.6/24 dev eth1
        - ip addr replace 6.6.6.6/32 dev lo
        - ip addr replace 10.10.10.10/32 dev lo

    R7:
      kind: linux
      image: quay.io/frrouting/frr:10.2.1
      binds:
        - ./configs/R7:/etc/frr
      exec:
        - ip addr replace 10.0.57.7/24 dev eth1
        - ip addr replace 7.7.7.7/32 dev lo
        - ip addr replace 10.10.10.10/32 dev lo

  links:
    # Core topology
    - endpoints: ["R1:eth1", "R2:eth1"]
    - endpoints: ["R2:eth2", "R3:eth1"]
    - endpoints: ["R1:eth2", "R4:eth1"]
    - endpoints: ["R4:eth2", "R5:eth1"]
    - endpoints: ["R5:eth2", "R3:eth2"]
    
    # Anycast server connections
    - endpoints: ["R2:eth3", "R6:eth1"]
    - endpoints: ["R5:eth3", "R7:eth1"]
TOPOLOGY

echo "✅ Containerlab topology with Krill and RPKI created"
echo ""

# Clean up any existing labs
echo "🧹 Cleaning up any existing labs..."
sudo containerlab destroy -t krill-test.clab.yml --cleanup 2>/dev/null || true
sudo containerlab destroy --all --cleanup 2>/dev/null || true

ORPHANED=$(sudo docker ps -a --filter "name=clab-bgp" -q)
if [ -n "$ORPHANED" ]; then
    sudo docker rm -f $ORPHANED >/dev/null 2>&1 || true
fi

echo "✅ Cleanup completed"
echo ""

# Deploy the lab
echo "🔧 Deploying BGP Anycast + Krill RPKI lab..."
sudo containerlab deploy -t krill-test.clab.yml

echo ""
echo "⏳ Waiting for services to start (30 seconds)..."
for i in {1..30}; do
    echo -n "."
    sleep 1
done
echo ""
echo ""

echo "🔧 Configuring Krill CA and ROAs..."
echo ""

# Get Krill container name
KRILL_CONTAINER=$(sudo docker ps --format '{{.Names}}' | grep krill)

if [ -z "$KRILL_CONTAINER" ]; then
    echo "❌ ERROR: Krill container not found!"
    exit 1
fi

echo "✅ Krill container: $KRILL_CONTAINER"

# Wait for Krill to be ready
echo "⏳ Waiting for Krill to be ready..."
until sudo docker exec "$KRILL_CONTAINER" curl -s http://localhost:3000/api/v1/stats 2>/dev/null | grep -q "version"; do
    echo -n "."
    sleep 2
done
echo ""
echo "✅ Krill is ready!"

# Get Krill TAL (Trust Anchor Locator)
echo "🔐 Getting Krill TAL..."
sudo docker exec "$KRILL_CONTAINER" krillc ta --format pem > configs/routinator/krill-tal.tal

# Update Routinator config with Krill TAL
cat > configs/routinator/routinator.conf << 'ROUTINATOR_CONF'
# RPKI cache directory
repository-dir = "/root/.rpki-cache/repository"

# RTR server configuration
rtr-listen = ["0.0.0.0:3324"]

# HTTP server configuration  
http-listen = ["0.0.0.0:8323"]

# Trust anchor locator for Krill
tal-files = ["/root/.rpki-cache/krill-tal.tal"]

# Validation refresh interval (seconds)
refresh = 600

# Stale object handling
stale = "reject"
ROUTINATOR_CONF

echo "✅ Krill TAL retrieved and Routinator configured"
echo ""

# Restart Routinator with updated config
echo "🔄 Restarting Routinator with Krill TAL..."
ROUTINATOR_CONTAINER=$(sudo docker ps --format '{{.Names}}' | grep routinator)
if [ -n "$ROUTINATOR_CONTAINER" ]; then
    sudo docker exec "$ROUTINATOR_CONTAINER" pkill routinator 2>/dev/null || true
    sleep 2
    sudo docker exec -d "$ROUTINATOR_CONTAINER" routinator --config /root/.rpki-cache/routinator.conf server
    echo "✅ Routinator restarted"
else
    echo "⚠️  Routinator container not found"
fi

echo ""
echo "⏳ Waiting for Routinator to start (15 seconds)..."
sleep 15

# Create CAs for AS65006 and AS65007
echo "🏢 Creating Certificate Authorities in Krill..."
sudo docker exec "$KRILL_CONTAINER" krillc bulk --ca as65006 --asn 65006 --ipv4 10.10.10.10/32
sudo docker exec "$KRILL_CONTAINER" krillc bulk --ca as65007 --asn 65007 --ipv4 10.10.10.10/32

echo "✅ Certificate Authorities created"
echo ""

# Add ROAs for the anycast scenario
echo "📜 Creating ROAs..."
# AS65006 is authorized for 10.10.10.10/32 (VALID)
sudo docker exec "$KRILL_CONTAINER" krillc roas add --ca as65006 --asn 65006 --prefix 10.10.10.10/32

# AS65006 is also authorized for its own loopback
sudo docker exec "$KRILL_CONTAINER" krillc roas add --ca as65006 --asn 65006 --prefix 6.6.6.6/32

# AS65007 is authorized for its own loopback (but NOT for 10.10.10.10/32)
sudo docker exec "$KRILL_CONTAINER" krillc roas add --ca as65007 --asn 65007 --prefix 7.7.7.7/32

echo "✅ ROAs created"
echo ""

# Wait for publication and validation
echo "⏳ Waiting for ROA publication and validation (30 seconds)..."
sleep 30

echo ""
echo "✅ BGP Anycast + Krill RPKI lab deployed successfully!"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "🎯 ANYCAST + RPKI LAB OVERVIEW (Krill Version)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "🌐 Topology:"
echo "   • Core Network: R1-R5 (AS 65001-65005)"
echo "   • Anycast Servers:"
echo "     - R6 (AS65006): 10.10.10.10/32 [RPKI VALID ✓]"
echo "     - R7 (AS65007): 10.10.10.10/32 [RPKI INVALID ✗]"
echo "   • RPKI Infrastructure: Krill CA + Routinator"
echo ""
echo "🔒 RPKI Configuration:"
echo "   • Krill generates real ROAs with X.509 certificates"
echo "   • AS65006 authorized for 10.10.10.10/32 (VALID)"
echo "   • AS65007 NOT authorized for 10.10.10.10/32 (INVALID)"
echo "   • RPKI module enabled with -M rpki flag"
echo ""
echo "🛣️  Path Analysis:"
echo "   WITHOUT RPKI:"
echo "   • SHORT: R1→R2→R6 (AS: 65002 65006) - Preferred"
echo "   • LONG:  R1→R4→R5→R7 (AS: 65004 65005 65007)"
echo ""
echo "   WITH RPKI ROV:"
echo "   • R6 path: VALID ✓ (can be used)"
echo "   • R7 path: INVALID ✗ (visible but marked invalid)"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "🔍 VERIFICATION COMMANDS"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "1. Check Krill status:"
echo "   sudo docker exec $KRILL_CONTAINER krillc stats"
echo "   sudo docker exec $KRILL_CONTAINER krillc cas list"
echo ""
echo "2. Check ROAs in Krill:"
echo "   sudo docker exec $KRILL_CONTAINER krillc roas show --ca as65006"
echo "   sudo docker exec $KRILL_CONTAINER krillc roas show --ca as65007"
echo ""
echo "3. Check RPKI cache status on R1:"
echo "   sudo docker exec clab-bgp-anycast-krill-R1 vtysh -c 'show rpki cache-connection'"
echo "   sudo docker exec clab-bgp-anycast-krill-R1 vtysh -c 'show rpki prefix-table'"
echo ""
echo "4. Check BGP routes with RPKI validation:"
echo "   sudo docker exec clab-bgp-anycast-krill-R1 vtysh -c 'show bgp ipv4 unicast 10.10.10.10/32'"
echo ""
echo "5. Check RPKI validation status:"
echo "   sudo docker exec clab-bgp-anycast-krill-R1 vtysh -c 'show bgp ipv4 unicast rpki valid'"
echo "   sudo docker exec clab-bgp-anycast-krill-R1 vtysh -c 'show bgp ipv4 unicast rpki invalid'"
echo ""
echo "6. Verify Routinator is running:"
echo "   curl -s http://localhost:8323/status"
echo "   sudo docker exec $ROUTINATOR_CONTAINER routinator vrps"
echo ""
echo "7. Test connectivity:"
echo "   sudo docker exec clab-bgp-anycast-krill-R1 ping -c 3 10.10.10.10"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "🎮 INTERACTIVE ACCESS"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Connect to routers:"
for router in R1 R2 R3 R4 R5 R6 R7; do
    echo "   $router: sudo docker exec -it clab-bgp-anycast-krill-$router vtysh"
done
echo ""
echo "Connect to Krill:"
echo "   sudo docker exec -it $KRILL_CONTAINER sh"
echo "   Krill UI: http://localhost:3000/"
echo ""
echo "Connect to Routinator:"
echo "   sudo docker exec -it $ROUTINATOR_CONTAINER sh"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "🧪 RPKI TESTING SCENARIOS"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "1. Verify RPKI Validation Status:"
echo "   # Check which path is selected"
echo "   sudo docker exec clab-bgp-anycast-krill-R1 vtysh -c 'show ip bgp 10.10.10.10/32'"
echo ""
echo "2. Test INVALID Route Filtering (apply route-map):"
echo "   sudo docker exec -it clab-bgp-anycast-krill-R1 vtysh"
echo "   R1# configure terminal"
echo "   R1(config)# route-map RPKI-FILTER permit 10"
echo "   R1(config-route-map)# match rpki valid"
echo "   R1(config-route-map)# exit"
echo "   R1(config)# route-map RPKI-FILTER deny 20"
echo "   R1(config-route-map)# match rpki invalid"
echo "   R1(config-route-map)# exit"
echo "   R1(config)# router bgp 65001"
echo "   R1(config-router)# address-family ipv4 unicast"
echo "   R1(config-router-af)# neighbor 10.0.12.2 route-map RPKI-FILTER in"
echo "   R1(config-router-af)# neighbor 10.0.14.4 route-map RPKI-FILTER in"
echo "   R1(config-router-af)# end"
echo "   R1# clear ip bgp *"
echo ""
echo "3. Simulate R6 Failure (Force to INVALID path):"
echo "   sudo docker exec clab-bgp-anycast-krill-R6 ip link set eth1 down"
echo "   sleep 30"
echo "   sudo docker exec clab-bgp-anycast-krill-R1 vtysh -c 'show ip bgp 10.10.10.10/32'"
echo "   # Restore"
echo "   sudo docker exec clab-bgp-anycast-krill-R6 ip link set eth1 up"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "💥 TEARDOWN"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "To destroy the lab:"
echo "   sudo containerlab destroy -t krill-test.clab.yml --cleanup"
echo ""
echo "✨ Setup complete!"
echo ""
echo "🔍 Quick RPKI Check:"
echo "   sudo docker exec clab-bgp-anycast-krill-R1 vtysh -c 'show rpki cache-connection'"
echo "   sudo docker exec clab-bgp-anycast-krill-R1 vtysh -c 'show bgp ipv4 10.10.10.10/32'"