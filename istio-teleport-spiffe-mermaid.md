# Istio + Teleport Workload Identity (SPIFFE) – Deployment Diagram

```mermaid
graph LR
  %% Teleport control plane
  subgraph TP[Teleport Control Plane]
    A[Auth/Proxy\nWorkload Identity Issuer]
  end

  %% Kubernetes cluster with Istio and tbot DaemonSet
  subgraph K8S[Kubernetes Cluster]
    direction TB
    CP["Istio Control Plane\nistiod"]

    subgraph N1[Node 1]
      direction TB
      T1["tbot DaemonSet\n(per-node agent)"]
      P1["App Pod\n+ Istio sidecar"]
    end

    subgraph N2[Node 2]
      direction TB
      T2["tbot DaemonSet\n(per-node agent)"]
      P2["App Pod\n+ Istio sidecar"]
    end
  end

  %% Flows
  A -->|gRPC: issue/renew X.509 SVIDs\n+ JWKS bundle for JWT SVIDs| T1
  A -->|gRPC: issue/renew X.509 SVIDs\n+ JWKS bundle for JWT SVIDs| T2

  T1 -->|SPIFFE Workload API socket\n/run/spire/sockets| P1
  T2 -->|SPIFFE Workload API socket\n/run/spire/sockets| P2

  CP -->|xDS + cert config| P1
  CP -->|xDS + cert config| P2

  P1 -- "mTLS (SPIFFE X.509 SVIDs)" --> P2

  %% Optional JWT SVID egress
  P1 -->|"Bearer JWT SVID (optional)\nEnvoy egress filter injects token"| X[External Service / Other Cluster]
```

Key points:
- tbot runs as a DaemonSet (one per node) and exposes the SPIFFE Workload API socket to pods on that node.
- Teleport issues and renews SVIDs (X.509, and JWT SVIDs on v16+) to tbot; JWKS is published by the proxy.
- Istio sidecars consume SPIFFE certs from the socket for mTLS; Istio control plane delivers xDS.
- Optional: for off-mesh/cross-cluster calls, an Envoy egress filter can inject a JWT SVID as a Bearer token.
