# ADR-0003: Empirical In-Place Active Migration Timeline and Defragmentation Lifecycle on GKE 1.37

- **Status**: Accepted
- **Date**: 2026-10-17

## Context

When `spec.activeMigration.optimizeRulePriority: true` is configured on a GKE `ComputeClass` (`cloud.google.com/v1`), operators need to know whether an in-place update to `spec.priorities` (such as promoting obtainable Google Axion Arm64 `n4a` Spot to Priority #1 via `make unlock-arm`) triggers **Active Migration** automatically or requires an external Pod scale event, and what node taints and timings occur during the migration.

## Empirical Observations on `ate-cluster` (`v1.37.0-gke.3503000`)

During live verification on `gke_mofilabs_us-central1-a_ate-cluster`:

1. **Zero-Touch In-Place Trigger**: Applying `manifests/03-computeclass-obtainable-arm.yaml` (`kubectl apply -f ...`) triggers **Active Migration** automatically without any Pod scaling event or edit to `Deployment/silicon-inspector` (`metadata.generation` remained `1`).
2. **Consolidation & Defragmentation Window (`~125s - 137s`)**:
   - With `autoscalingPolicy.consolidationDelayMinutes: 1`, Cluster Autoscaler waits for the consolidation window before initiating replacement.
   - At `+137s` after `make unlock-arm`, Cluster Autoscaler marks the Priority #2 fallback node (`n4d-highcpu-2`, `amd64` Spot) with:
     - `autoscaling.gke.io/defrag-candidate=<epoch>:NoSchedule`
     - `autoscaling.gke.io/defrag-soft-candidate=<epoch>:PreferNoSchedule`
   - Simultaneously, Node Pool Auto-Creation provisions a Priority #1 Google Axion Arm64 (`n4a-highcpu-1`, `arm64` Spot) node pool (`CA[su=InProgress]`).
3. **Untainted Arm64 Node Registration & Drain (`~162s - 192s`)**:
   - At `+162s`, the `n4a-highcpu-1` (`arm64` Spot) node registers with `cloud.google.com/compute-class=obtainable-compute:NoSchedule` and **zero** `kubernetes.io/arch=arm64:NoSchedule` taint (`architectureTaintBehavior: NONE`).
   - At `+178s`, the `n4a-highcpu-1` nodes reach `Ready`, and Cluster Autoscaler cordons and drains the `n4d-highcpu-2` (`amd64`) node by applying `ToBeDeletedByClusterAutoscaler=<epoch>:NoSchedule` and `node.kubernetes.io/unschedulable=:NoSchedule` (`Ready,SchedulingDisabled`).
   - At `+192s`, both `silicon-inspector` Pods are `1/1 Running` on `n4a-highcpu-1` (`ARCH=aarch64`, `CPU implementer 0x41 / CPU part 0xd8e` Arm Neoverse-N3), and the drained `n4d` node is terminated.

## Decision

- Keep `autoscalingPolicy.consolidationDelayMinutes: 1` on `ComputeClass/obtainable-compute` so in-place priority updates trigger **Active Migration** within ~2–3 minutes.
- In `hack/verify-e2e.sh` and `hack/watch.sh`, surface both `configmap/cluster-autoscaler-status` activity and the `autoscaling.gke.io/defrag-candidate` / `ToBeDeletedByClusterAutoscaler` taints so operators can observe each phase of the migration live.
