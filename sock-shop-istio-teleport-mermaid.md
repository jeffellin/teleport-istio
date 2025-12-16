# Sock Shop on Istio + Teleport Workload Identity (SPIFFE)

```mermaid
graph LR
  %% Teleport control plane
  subgraph TP[Teleport Control Plane]
    AUTH["Auth/Proxy\nWorkload Identity Issuer"]
  end

  %% Kubernetes cluster (two illustrative nodes)
  subgraph K8S["Kubernetes Cluster (sock-shop namespace)"]
    direction TB
    ISTIO["Istio Control Plane\nistiod"]

    subgraph NODE1[Node 1]
      direction TB
      TDS1["tbot DaemonSet\n(per-node agent)"]
      FE["front-end pod\n+ Istio sidecar"]
      ORD["orders pod\n+ Istio sidecar"]
    end

    subgraph NODE2[Node 2]
      direction TB
      TDS2["tbot DaemonSet\n(per-node agent)"]
      CART["carts pod\n+ Istio sidecar"]
      CDB["carts-db pod\n+ Istio sidecar"]
    end
  end

  %% Issuance flows
  AUTH -->|"gRPC: issue/renew X.509 SVIDs\n+ JWKS bundle for JWT SVIDs"| TDS1
  AUTH -->|"gRPC: issue/renew X.509 SVIDs\n+ JWKS bundle for JWT SVIDs"| TDS2

  %% Workload API sockets
  TDS1 -->|"SPIFFE Workload API socket\n/run/spire/sockets"| FE
  TDS1 -->|"SPIFFE Workload API socket\n/run/spire/sockets"| ORD
  TDS2 -->|"SPIFFE Workload API socket\n/run/spire/sockets"| CART
  TDS2 -->|"SPIFFE Workload API socket\n/run/spire/sockets"| CDB

  %% Istio config to sidecars
  ISTIO -->|"xDS + SPIFFE cert config"| FE
  ISTIO -->|"xDS + SPIFFE cert config"| ORD
  ISTIO -->|"xDS + SPIFFE cert config"| CART
  ISTIO -->|"xDS + SPIFFE cert config"| CDB

  %% mTLS traffic inside mesh
  FE -- "mTLS (SPIFFE X.509 SVIDs)" --> ORD
  ORD -- "mTLS (SPIFFE X.509 SVIDs)" --> CART
  CART -- "mTLS (SPIFFE X.509 SVIDs)" --> CDB

  %% Optional JWT SVID egress from front-end
  FE -->|"Bearer JWT SVID (optional)\nEnvoy egress filter injects token"| EXT["External Service / Other Cluster"]
```

Key points:
- Sock Shop pods run with Istio sidecars; identities come from Teleport via tbot DaemonSet sockets on each node.
- Teleport issues SPIFFE SVIDs (X.509; JWT SVIDs on v16+) to tbot. Istio uses them for service-to-service mTLS.
- The socket path `/run/spire/sockets` is hostPath-mounted into injected pods so Envoy can read SVIDs.
- Optional egress pattern: front-end can attach a JWT SVID for off-mesh calls via an Envoy egress filter and helper sidecar.
