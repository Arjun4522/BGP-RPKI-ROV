#!/bin/bash

# =============================================================================
# Step 1: Setup basic topology and project structure
# =============================================================================

set -e

echo "🚀 Step 1: Setting up basic topology and project structure..."
echo "=============================================================="
echo ""

# Create directory structure
echo "📁 Creating directory structure..."
mkdir -p configs/{R1,R2,R3,R4,R5,R6,R7,routinator,krill}

# Create Krill configuration
echo "🔧 Creating Krill configuration..."
cat > configs/krill/krill.conf << 'KRILL_CONF'
log_level = "Info"
admin_token = "secret"
http_listen = "0.0.0.0:3000"
data_dir = "/var/krill/data"
ta_support_enabled = true

[repository]
type = "embedded"
contact = "embedded@example.net"

[ca]
allow_rfc_6487_skif = true

[publication]
type = "embedded"

[rrdp]
base_uri = "https://127.0.0.1:3001/rrdp/"
notification_uri = "https://127.0.0.1:3001/rrdp/notification.xml"
bind_address = "0.0.0.0:3001"

[rsync]
base_uri = "rsync://127.0.0.1/repo/"

# ⭐ ADD THIS TESTBED SECTION ⭐
[testbed]
rrdp_base_uri = "https://127.0.0.1:3001/rrdp/"
rsync_jail = "rsync://127.0.0.1/repo/"
ta_aia = "rsync://127.0.0.1/ta/ta.cer"
ta_uri = "https://127.0.0.1:3001/ta/ta.cer"


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

# Trust anchor locator for Krill (will be updated later)
tal-files = ["/root/.rpki-cache/tals/my-ca.tal"]

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
        KRILL_ADMIN_TOKEN: secret
        KRILL_LOG_LEVEL: Info
        KRILL_TA_SUPPORT_ENABLED: "true"

      binds:
        - ./configs/krill/krill.conf:/etc/krill.conf
        - ./configs/krill:/var/krill/data

    routinator:
      kind: linux
      image: nlnetlabs/routinator:latest
      user: root
      ports:
        - "3324:3324"
        - "8323:8323"
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

echo "🎉 Step 1 completed successfully!"
echo "Next step: Run 2-init-krill.sh"