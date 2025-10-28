# 🛰️ BGP Anycast + RPKI ROV Testbed
**Containerlab + FRRouting + Routinator + SLURM**

A self-contained lab demonstrating **BGP Anycast** with **RPKI Route Origin Validation (ROV)**.  
Invalid routes are filtered — only the **valid** Anycast node wins.

---

## 📘 Overview

| Component       | Role |
|----------------|------|
| **Containerlab** | Builds virtual topology |
| **FRRouting (FRR)** | BGP + RPKI ROV |
| **Routinator** | Local RPKI validator + RTR server |
| **SLURM** | Local ROA assertions (no real RIRs) |
| **Anycast Prefix** | `10.10.10.10/32` |

> **Goal**: Only `AS65006` is valid → traffic goes to `R6`, not `R7`.

---

## 🧩 Topology

```
                  ┌──────────┐
                  │ Routinator│
                  │ (RPKI CA) │
                  └─────┬─────┘
                        │ RTR (TCP 3323)
              ┌─────────┴─────────┐
              │                   │
           ┌──┴──┐             ┌──┴──┐
           │  R1 │-------------│  R2 │
           └──┬──┘             └──┬──┘
              │                     │
       ┌──────┴───────┐       ┌─────┴──────┐
       │   R6 (AS65006)|      │  R7 (AS65007)│
       │ 10.10.10.10/32│      │ 10.10.10.10/32│
       └───────────────┘      └───────────────┘
```

- `R6` → **Valid** (ROA via SLURM)  
- `R7` → **Invalid** (no ROA)  
- `R1` → Validates via Routinator, enforces ROV

---

## ⚙️ Setup

### 1. Clone & Deploy

```bash
git clone https://github.com/Arjun4522/BGP-RPKI-ROV
cd BGP-rpki-prod
chmod +x roa-test.sh setup-anycast-rpki.sh
sudo ./setup-anycast-rpki.sh
sudo ./roa-test.sh
```

Launches: `R1`, `R2`,... `R6`, `R7`, `routinator`

---

### 2. Load SLURM (Local ROA)

**File**: `configs/routinator/slurm.json`

```json
{
  "slurmVersion": 1,
  "validationOutputFilters": { "prefixFilters": [] },
  "locallyAddedAssertions": {
    "prefixAssertions": [
      {
        "asn": 65006,
        "prefix": "10.10.10.10/32",
        "maxPrefixLength": 32,
        "comment": "R6 authorized (VALID)"
      }
    ]
  }
}
```

Apply:

```bash
sudo docker exec clab-bgp-anycast-rpki-routinator routinator reload
```

---

### 3. Verify VRP in Routinator

```bash
sudo docker exec clab-bgp-anycast-rpki-routinator routinator vrps | grep 10.10.10.10
```

**Expected**:
```
10.10.10.10/32,AS65006,maxlen=32,source=slurm.json
```

---

## 🔍 Validation

### Enter R1

```bash
sudo docker exec -it clab-bgp-anycast-rpki-R1 vtysh
```

---

### 1. RPKI State

```bash
R1# show bgp rpki
```

**Expected**:
```
Prefix             Origin-AS  State
10.10.10.10/32     65006      valid
10.10.10.10/32     65007      invalid
```

---

### 2. BGP Table

```bash
R1# show bgp ipv4 unicast 10.10.10.10/32
```

**Expected**:
```
BGP routing table entry for 10.10.10.10/32
Paths: (1 available, best #1)
  65006
    10.0.0.6 from 10.0.0.6
    Origin IGP, valid, best
```

> Only `AS65006` is installed.

---

### 3. IP Route

```bash
R1# show ip route 10.10.10.10
```

**Expected**:
```
B  10.10.10.10/32 [20/0] via 10.0.0.6, eth1
```

---

### 4. Traceroute (from host1)

```bash
sudo docker exec clab-bgp-anycast-rpki-host1 traceroute 10.10.10.10
```

**Expected**:
```
1  192.168.10.1
2  10.0.0.6 (R6)  ✅
```

> Traffic goes to **R6**, not R7.

---

## 🧠 How It Works

| Step | Action |
|------|--------|
| 1 | SLURM adds ROA: `AS65006 → 10.10.10.10/32` |
| 2 | Routinator → VRP |
| 3 | R1 fetches VRP via RTR (TCP 3323) |
| 4 | BGP compares origin |
| 5 | **Valid → install**, **Invalid → drop** |

---

## 📂 Project Structure

```
BGP-rpki-prod/
├── bgp-anycast-rpki.clab.yml
├── configs/
│   ├── frr/
│   │   ├── R1.conf
│   │   ├── R2.conf
│   │   ├── R6.conf
│   │   └── R7.conf
│   └── routinator/
│       └── slurm.json
└── README.md
```

---

## 🛠️ Containerlab Topology (`bgp-anycast-rpki.clab.yml`)

```yaml
name: bgp-anycast-rpki
mgmt:
  network: clab
  ipv4-subnet: 172.20.20.0/24

topology:
  kinds:
    linux:
      image: alpine:latest
      exec:
        - "apk add --no-cache iproute2 traceroute"
    frr:
      image: frrouting/frr:latest
    routinator:
      image: nlnetlabs/routinator:latest

  nodes:
    R1:
      kind: frr
      binds:
        - configs/frr/R1.conf:/etc/frr/frr.conf
      mgmt_ipv4: 172.20.20.2
    R2:
      kind: frr
      binds:
        - configs/frr/R2.conf:/etc/frr/frr.conf
      mgmt_ipv4: 172.20.20.3
    R6:
      kind: frr
      binds:
        - configs/frr/R6.conf:/etc/frr/frr.conf
      mgmt_ipv4: 172.20.20.6
    R7:
      kind: frr
      binds:
        - configs/frr/R7.conf:/etc/frr/frr.conf
      mgmt_ipv4: 172.20.20.7
    routinator:
      kind: routinator
      binds:
        - configs/routinator/slurm.json:/etc/routinator/slurm.json
      cmd: --slurm /etc/routinator/slurm.json
      mgmt_ipv4: 172.20.20.10
    host1:
      kind: linux
      exec:
        - "ip route add 10.10.10.10/32 via 192.168.10.1"
      mgmt_ipv4: 172.20.20.100
    host2:
      kind: linux
      mgmt_ipv4: 172.20.20.101

  links:
    - endpoints: ["R1:eth1", "R6:eth1"]
    - endpoints: ["R1:eth2", "R7:eth1"]
    - endpoints: ["R1:eth3", "R2:eth1"]
    - endpoints: ["R1:eth4", "host1:eth1"]
    - endpoints: ["R2:eth2", "host2:eth1"]
    - endpoints: ["R1:eth5", "routinator:eth1"]
```

---

## 🧱 Access

```bash
# FRR
sudo docker exec -it clab-bgp-anycast-rpki-R1 vtysh

# Linux
sudo docker exec -it clab-bgp-anycast-rpki-R6 bash

# Destroy
sudo containerlab destroy -t bgp-anycast-rpki.clab.yml
```

---

## 📦 Expected Results

| Command | Result |
|--------|--------|
| `show bgp rpki` | `65006=valid`, `65007=invalid` |
| `show ip route 10.10.10.10` | via `10.0.0.6` (R6) |
| `traceroute 10.10.10.10` | ends at `R6` |
| `routinator vrps` | only `AS65006` |

---

## ✅ Outcome

- Valid route → **installed & used**  
- Invalid route → **filtered at R1**  
- Traffic → **only to R6**  
- Full **RPKI ROV in Anycast**

---

## 🧾 References

- [RFC 8416 – SLURM](https://datatracker.ietf.org/doc/html/rfc8416)
- [Routinator](https://github.com/NLnetLabs/routinator)
- [FRR RPKI](https://docs.frrouting.org/en/latest/rpki.html)
- [Containerlab](https://containerlab.dev)

---

**Deploy now**:

```bash
sudo containerlab deploy -t bgp-anycast-rpki.clab.yml
```

You're running **real RPKI filtering** in 30 seconds.
