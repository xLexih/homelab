# Architecture

Detailed explanation of how the cluster works.

## Overview

```mermaid
flowchart TB
    subgraph WG[" WireGuard Full Mesh (10.100.0.0/24) "]
        direction TB
        M1[" master1 (init) "]
        M2[" master2 (HAProxy) "]
        M3[" master3 (HAProxy) "]
        M1 --- M2
        M2 --- M3
        M1 --- M3
    end

    KV[" kube‑vip VIP: 192.168.2.150 "]
    M1 --- KV
    M2 --- KV
    M3 --- KV
```

## Components

| Component | Version      | Purpose                                            |
| --------- | ------------ | -------------------------------------------------- |
| k3s       | 1.34.3       | Lightweight Kubernetes with embedded etcd          |
| WireGuard | 1.0.20250521 | Encrypted full‑mesh overlay network                |
| Cilium    | 1.19.3       | CNI, NetworkPolicy, LoadBalancer IP pools          |
| kube‑vip  | 0.9.8        | Layer 2 VIP announcement for LoadBalancer services |
| Longhorn  | 1.11.1       | Distributed replicated block storage               |
| HAProxy   | (NixOS)      | Control‑plane load balancer on non‑init masters    |

---

## WireGuard Mesh

Every node maintains a direct WireGuard tunnel to every other node, forming a full mesh. This design eliminates single points of failure and gives each pod‑to‑pod flow the shortest path.

```mermaid
flowchart TB
    subgraph PHYSICAL[" Physical subnets "]
        HOME[" Home LAN 192.168.2.0/24 "]
        CLOUD[" Cloud VPC 10.10.0.0/24 "]
    end

    subgraph WG[" WireGuard overlay 10.100.0.0/24 "]
        M1[" master1 WG: 10.100.0.1 "]
        M2[" master2 WG: 10.100.0.2 "]
        M3[" master3 WG: 10.100.0.3 "]
    end

    HOME --> M1
    CLOUD --> M3

    M1 --- M2
    M2 --- M3
    M1 --- M3
```

**Why full mesh?**

- No central relay – traffic follows the direct path between nodes.
- Works across NAT with `persistentKeepalive = 25`.
- Control‑plane and pod traffic never leaves the encrypted overlay.

**NAT Traversal:**

```mermaid
sequenceDiagram
    participant A as Node A (behind NAT)
    participant B as Node B (public IP)
    A->>B: UDP to B:51820
    B-->>A: Response (NAT hole punched)
    Note over A,B: Bidirectional tunnel established
```

**Endpoint resolution logic:**

1. If a node has an explicit `endpoint`, that DNS name or IP is used.
2. Otherwise, if `cluster.network.domain` is set, the endpoint becomes `<nodeName>.<domain>`.
3. If neither is set, the node's `lanIP` is used (requires static IP).
4. Nodes using DHCP **must** provide an `endpoint` or rely on a cluster‑wide domain; otherwise validation fails.

---

## k3s High Availability

### Control Plane

```mermaid
flowchart LR
    CLIENT[" kubectl "] --> HAPROXY[" HAProxy 127.0.0.1:6443 "]
    HAPROXY --> M1[" master1 (init) "]
    HAPROXY --> M2[" master2 "]
    HAPROXY --> M3[" master3 "]

    subgraph ETCD[" etcd Raft Cluster "]
        M1 <--> M2
        M2 <--> M3
        M1 <--> M3
    end
```

| Step | Action                                                                    |
| ---- | ------------------------------------------------------------------------- |
| 1    | Init node starts with `--cluster-init`.                                   |
| 2    | Other masters join via `--server https://<init-wg-ip>:6443`.              |
| 3    | etcd forms a Raft cluster (quorum required for writes).                   |
| 4    | HAProxy on non‑init masters load‑balances API traffic across all masters. |

**HAProxy configuration** (relevant snippet):

```
defaults
  mode tcp
  timeout connect 5s
  timeout client 50s
  timeout server 50s
  default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250

backend k3s-masters
  balance roundrobin
  server master1 master1:6443 check
  server master2 master2:6443 check
  server master3 master3:6443 check
```

---

## LoadBalancer IPs

### kube‑vip Leader Election

```mermaid
sequenceDiagram
    participant K1 as kube‑vip (master1)
    participant K2 as kube‑vip (master2)
    participant K3 as kube‑vip (master3)
    participant API as Kubernetes API / Lease
    participant LAN as LAN (ARP)

    Note over K1,API: Initial election
    K1->>API: Acquire lease
    API-->>K1: Success
    K1->>LAN: Gratuitous ARP: .150 → master1 MAC

    Note over K2,API: Standby
    K2->>API: Try acquire → held by master1
    K3->>API: Try acquire → held by master1

    Note over K1,LAN: Leader fails
    K1--xAPI: (crashes)
    K2->>API: Acquire expired lease
    API-->>K2: Success → new leader
    K2->>LAN: Gratuitous ARP: .150 → master2 MAC
```

Lease durations are set to 300 s with a 120‑s renewal deadline, providing tolerance against short API‑server stalls

### Service with Real Client IP

```mermaid
flowchart LR
    CLIENT[" Client 1.2.3.4 "] -->|" TCP :443 "| VIP[" VIP 192.168.2.150 "]
    VIP --> IPTABLES[" iptables DNAT "]
    IPTABLES -->|" source preserved "| POD[" APISix Pod "]
    POD -->|" X‑Real‑IP: 1.2.3.4 "| BACKEND[" Backend Pod "]
```

**Required:** `externalTrafficPolicy: Local` on the Service, and Cilium `loadBalancer.mode=hybrid` with DSR over Geneve.

### Cilium IP Pool Allocation

```mermaid
flowchart TB
    POOL[" CiliumLoadBalancerIPPool lb‑pool‑home 192.168.2.150‑160 "]
    SVC[" Service type: LoadBalancer selector: loadbalancer.home.enabled=true "]
    ALLOC[" IP assigned: 192.168.2.150 "]
    RESULT[" status.loadBalancer.ingress = 192.168.2.150 "]

    SVC -->| matches | POOL
    POOL -->| allocates | ALLOC
    ALLOC --> RESULT
```

---

## Storage (Longhorn)

### Volume with 2 Replicas

```mermaid
flowchart TB
    subgraph POD[" Pod on master1 "]
        APP[" Application "]
        PVC[" PVC: 100 Gi "]
    end

    subgraph ENGINE[" Longhorn Engine (master1) "]
        ENG[" Engine "]
        R1[" Replica 1 "]
    end

    subgraph M2[" master2 "]
        R2[" Replica 2 "]
    end

    APP --> PVC
    PVC --> ENG
    ENG <-->| sync | R1
    ENG <-->| sync | R2
```

**Recovery scenarios:**

| Failure           | Recovery                                                  |
| ----------------- | --------------------------------------------------------- |
| Replica node dies | Engine rebuilds replica on another healthy node.          |
| Engine node dies  | Engine restarts elsewhere, reattaches surviving replicas. |
| Disk corruption   | Volume is rebuilt from a healthy replica.                 |

Tunings applied for homelab clusters: `replicaAutoBalance=least-effort`, `storageOverProvisioningPercentage=100`, `defaultDataLocality=best-effort`.

---

## Network Policy

```mermaid
flowchart TB
    subgraph NS1[" namespace: apisix "]
        APISIX[" APISix Pod "]
    end
    subgraph NS2[" namespace: copyparty "]
        COPY[" CopyParty Pod "]
    end
    subgraph NS3[" namespace: default "]
        RANDOM[" Random Pod "]
    end

    APISIX -->| allowed | COPY
    RANDOM -.->| BLOCKED | COPY
```

Enforced by Cilium `NetworkPolicy` objects.

---

## Complete Traffic Flow: WAN → Pod

```mermaid
flowchart TB
    WAN[" Internet Client 1.2.3.4 "]
    DNS[" DNS: files.example.com → 192.168.2.150 "]
    ROUTER[" Home Router "]

    subgraph NODE[" master1 (kube‑vip leader) "]
        VIP[" VIP 192.168.2.150 "]
        IPTABLES[" iptables KUBE‑EXTERNAL "]
        CILIUM[" Cilium eBPF "]
        APISIX[" APISix Pod 10.42.0.5:9080 "]
    end

    COPY[" CopyParty Pod 10.42.1.3:3923 "]

    WAN -->|" HTTPS :443 "| DNS
    DNS --> ROUTER
    ROUTER -->|" ARP "| VIP
    VIP --> IPTABLES
    IPTABLES -->|" DNAT → NodePort "| CILIUM
    CILIUM -->|" proxy "| APISIX
    APISIX -->|" route /files/* "| COPY
```

### Step‑by‑Step Breakdown

```mermaid
sequenceDiagram
    participant C as Client (1.2.3.4)
    participant D as DNS
    participant R as Router
    participant KV as kube‑vip
    participant IPT as iptables
    participant CIL as Cilium
    participant API as APISix
    participant APP as CopyParty

    Note over C,D: Step 1: DNS
    C->>D: Query files.example.com
    D-->>C: 192.168.2.150

    Note over C,R: Step 2: Routing
    C->>R: TCP :443 → 192.168.2.150
    R->>R: ARP who‑has .150?

    Note over R,KV: Step 3: ARP
    KV->>R: .150 is at master1 MAC
    R->>KV: Packet → master1

    Note over KV,IPT: Step 4: iptables
    KV->>IPT: dst .150:443
    IPT->>IPT: DNAT → NodePort

    Note over IPT,CIL: Step 5: Cilium DNAT
    IPT->>CIL: src 1.2.3.4 preserved
    CIL->>CIL: Service → Pod translation

    Note over CIL,API: Step 6: Gateway
    CIL->>API: 10.42.0.5:9080
    API->>API: Route lookup

    Note over API,APP: Step 7: Backend
    API->>APP: X‑Real‑IP: 1.2.3.4
    APP->>APP: Logs show real IP
```

### Packet Transformations

```mermaid
flowchart LR
    subgraph P1[" At Client "]
        PKT1[" src: 1.2.3.4:54321<br/>dst: 192.168.2.150:443 "]
    end
    subgraph P2[" After iptables "]
        PKT2[" src: 1.2.3.4:54321<br/>dst: 192.168.2.105:31234 (NodePort) "]
    end
    subgraph P3[" After Cilium "]
        PKT3[" src: 1.2.3.4:54321<br/>dst: 10.42.0.5:9080 (Pod IP) "]
    end

    P1 --> P2 --> P3
```

### What Could Go Wrong?

| Issue                            | Symptom                      | Cause                                            |
| -------------------------------- | ---------------------------- | ------------------------------------------------ |
| No anti‑affinity on APISix       | Intermittent 503 errors      | VIP traffic hits a node without an APISix pod.   |
| `externalTrafficPolicy: Cluster` | Real IP lost (shows node IP) | SNAT when forwarding to another node.            |
| kube‑vip leader dies             | ~1–2 s downtime              | Normal lease expiration; new leader takes over.  |
| Cilium not ready                 | Connection refused           | Pod exists but Cilium hasn't programmed BPF yet. |

---

## Deployment Model

The cluster is deployed using the `deploy` script (see README). Key points:

- **Init node** – installed via `nixos-anywhere` (`deploy init master1`).
- **Other nodes** – updated in place with `nixos-rebuild` (`deploy rebuild <node>`).
- All commands support an optional `--jump` bastion for nodes behind a firewall.
- Cluster validation (`helpers.validateCluster`) catches misconfigurations (duplicate IPs, missing endpoints, etc.) at evaluation time.

---

<p align="right"><sub>Generated by Deepseek-V4</sub></p>
