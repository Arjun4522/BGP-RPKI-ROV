#!/bin/bash

# =============================================================================
# BGP Anycast + RPKI ROV Testbed (CORRECTED)
# Containerlab + FRR + Routinator
# =============================================================================
# Anycast IP : 10.10.10.10/32
# ROA Status : AS65006 → VALID   (R6 - Short Path)
#            : AS65007 → INVALID (R7 - Long Path)
# =============================================================================

set -e

echo "🚀 Setting up BGP Anycast + RPKI Testbed..."
echo "================================================"
echo ""

# Create directory structure
echo "📁 Creating directory structure..."
mkdir -p configs/{R1,R2,R3,R4,R5,R6,R7,routinator}

# Create Routinator configuration file
echo "📝 Creating Routinator configuration..."
cat > configs/routinator/routinator.conf << 'ROUTINATOR_CONF'
# RPKI cache directory
repository-dir = "/root/.rpki-cache/repository"

# RTR server configuration
rtr-listen = ["0.0.0.0:3324"]

# HTTP server configuration  
http-listen = ["0.0.0.0:8323"]

# Local exceptions file for test ROAs - FIXED PATH
exceptions = ["/root/.rpki-cache/local-exceptions.json"]

# Validation refresh interval (seconds)
refresh = 600

# Stale object handling
stale = "reject"
ROUTINATOR_CONF

# Create ROA configuration for Routinator - FIXED FORMAT
echo "📝 Creating RPKI ROA configuration..."
cat > configs/routinator/local-exceptions.json << 'ROA_CONFIG'
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
ROA_CONFIG

echo "✅ RPKI ROA configuration created"
echo "   • AS65006 authorized for 10.10.10.10/32 (VALID)"
echo "   • AS65007 NOT authorized for 10.10.10.10/32 (INVALID)"
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
 rpki cache 172.20.20.6 3323 preference 1
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
 rpki cache 172.20.20.6 3323 preference 1
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
 rpki cache 172.20.20.6 3323 preference 1
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
 rpki cache 172.20.20.6 3323 preference 1
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
 rpki cache 172.20.20.6 3323 preference 1
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
 rpki cache 172.20.20.6 3323 preference 1
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
 rpki cache 172.20.20.6 3323 preference 1
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

# Create the containerlab topology file with Routinator
echo "📋 Creating containerlab topology with RPKI..."
cat > bgp-anycast-rpki.clab.yml << 'TOPOLOGY'
name: bgp-anycast-rpki

topology:
  nodes:
    routinator:
      kind: linux
      image: nlnetlabs/routinator:latest
      user: root
      ports:
        - "3323:3324"
        - "8323:8323"
        - "9556:9556"

      entrypoint: /sbin/tini -- routinator --config /root/.rpki-cache/routinator.conf server
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

echo "✅ Containerlab topology with RPKI created"
echo ""

# Clean up any existing labs
echo "🧹 Cleaning up any existing labs..."
sudo containerlab destroy -t bgp-anycast-rpki.clab.yml --cleanup 2>/dev/null || true
sudo containerlab destroy -t bgp-anycast.clab.yml --cleanup 2>/dev/null || true
sudo containerlab destroy --all --cleanup 2>/dev/null || true

ORPHANED=$(sudo docker ps -a --filter "name=clab-bgp" -q)
if [ -n "$ORPHANED" ]; then
    sudo docker rm -f $ORPHANED >/dev/null 2>&1 || true
fi

echo "✅ Cleanup completed"
echo ""

# Deploy the lab
echo "🔧 Deploying BGP Anycast + RPKI lab..."
sudo containerlab deploy -t bgp-anycast-rpki.clab.yml

echo ""
echo "⏳ Waiting for RPKI and BGP to stabilize (60 seconds)..."
for i in {1..60}; do
    echo -n "."
    sleep 1
done
echo ""
echo ""

echo "✅ BGP Anycast + RPKI lab deployed successfully!"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "🎯 ANYCAST + RPKI LAB OVERVIEW"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "🌐 Topology:"
echo "   • Core Network: R1-R5 (AS 65001-65005)"
echo "   • Anycast Servers:"
echo "     - R6 (AS65006): 10.10.10.10/32 [RPKI VALID ✓]"
echo "     - R7 (AS65007): 10.10.10.10/32 [RPKI INVALID ✗]"
echo "   • RPKI Validator: Routinator"
echo ""
echo "🔒 RPKI Configuration:"
echo "   • ROA for 10.10.10.10/32 → AS65006 (VALID)"
echo "   • R7's announcement will be INVALID"
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
echo "1. Check RPKI cache status on R1:"
echo "   sudo docker exec clab-bgp-anycast-rpki-R1 vtysh -c 'show rpki cache-connection'"
echo "   sudo docker exec clab-bgp-anycast-rpki-R1 vtysh -c 'show rpki prefix-table'"
echo ""
echo "2. Check BGP routes with RPKI validation:"
echo "   sudo docker exec clab-bgp-anycast-rpki-R1 vtysh -c 'show bgp ipv4 unicast 10.10.10.10/32'"
echo ""
echo "3. Check RPKI validation status:"
echo "   sudo docker exec clab-bgp-anycast-rpki-R1 vtysh -c 'show bgp ipv4 unicast rpki valid'"
echo "   sudo docker exec clab-bgp-anycast-rpki-R1 vtysh -c 'show bgp ipv4 unicast rpki invalid'"
echo ""
echo "4. Verify Routinator is running:"
echo "   curl -s http://localhost:9556/metrics | grep routinator"
echo "   sudo docker exec clab-bgp-anycast-rpki-routinator routinator vrps"
echo ""
echo "5. Test connectivity:"
echo "   sudo docker exec clab-bgp-anycast-rpki-R1 ping -c 3 10.10.10.10"
echo ""
echo "6. Run verification script:"
echo "   sudo ./roa.sh"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "🎮 INTERACTIVE ACCESS"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Connect to routers:"
for router in R1 R2 R3 R4 R5 R6 R7; do
    echo "   $router: sudo docker exec -it clab-bgp-anycast-rpki-$router vtysh"
done
echo ""
echo "Connect to Routinator:"
echo "   sudo docker exec -it clab-bgp-anycast-rpki-routinator sh"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "🧪 RPKI TESTING SCENARIOS"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "1. Verify RPKI Validation Status:"
echo "   # Check which path is selected"
echo "   sudo docker exec clab-bgp-anycast-rpki-R1 vtysh -c 'show ip bgp 10.10.10.10/32'"
echo ""
echo "2. Test INVALID Route Filtering (apply route-map):"
echo "   sudo docker exec -it clab-bgp-anycast-rpki-R1 vtysh"
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
echo "   sudo docker exec clab-bgp-anycast-rpki-R6 ip link set eth1 down"
echo "   sleep 30"
echo "   sudo docker exec clab-bgp-anycast-rpki-R1 vtysh -c 'show ip bgp 10.10.10.10/32'"
echo "   # Restore"
echo "   sudo docker exec clab-bgp-anycast-rpki-R6 ip link set eth1 up"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "💥 TEARDOWN"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "To destroy the lab:"
echo "   sudo containerlab destroy -t bgp-anycast-rpki.clab.yml --cleanup"
echo ""

echo "✨ Setup complete!"
echo ""
echo "🔍 Quick RPKI Check:"
echo "   sudo docker exec clab-bgp-anycast-rpki-R1 vtysh -c 'show rpki cache-connection'"
echo "   sudo docker exec clab-bgp-anycast-rpki-R1 vtysh -c 'show bgp ipv4 10.10.10.10/32'"
