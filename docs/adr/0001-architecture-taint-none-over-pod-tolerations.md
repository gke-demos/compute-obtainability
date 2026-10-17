# ADR-0001: Use ComputeClass `architectureTaintBehavior: NONE` Instead of Pod-Level Arm64 Tolerations

- **Status**: Accepted
- **Date**: 2026-10-17

## Context

Most container base images (`alpine`, `python`, `golang`, `nginx`, `redis`, `distroless`) publish multi-architecture OCI image indexes supporting both `linux/amd64` (`x86_64`) and `linux/arm64` (`aarch64`). However, in GKE, Arm64 node pools (`n4a`, `c4a`, `t2a`) are tainted by default with `kubernetes.io/arch=arm64:NoSchedule`.

Because of that default taint, a standard Deployment requesting a `ComputeClass` cannot fail over or migrate between x86 (`n4`, `n4d`, `c4`, `c4d`) and Arm (`n4a`, `c4a`, `t2a`) priority rules unless every Deployment in the cluster is modified to include an explicit `toleration` for `kubernetes.io/arch=arm64:NoSchedule`.

## Decision

We configure `spec.nodePoolConfig.taintConfig.architectureTaintBehavior: NONE` on the `obtainable-compute` `ComputeClass` and keep `Deployment/silicon-inspector` completely free of architecture `tolerations` or `kubernetes.io/arch` selectors.

## Consequences

- **Platform-owned obtainability**: Platform engineers can add Google Axion Arm64 (`n4a`, `c4a`) and x86 (`n4d`, `n4`) rules into a single `ComputeClass` Obtainability Ladder without editing application manifests.
- **Safety boundary**: Only workloads that opt into the `obtainable-compute` `ComputeClass` (via `nodeSelector: { cloud.google.com/compute-class: obtainable-compute }` or namespace default) schedule onto these untainted Arm64 nodes, because GKE still applies the `cloud.google.com/compute-class=obtainable-compute:NoSchedule` taint and matching Pod toleration automatically.
