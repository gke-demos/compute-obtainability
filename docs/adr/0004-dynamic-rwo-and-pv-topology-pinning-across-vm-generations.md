# ADR-0004: Cross-Generation Stateful Obtainability with `dynamic-rwo` and PV Disk-Topology Pinning

- **Status:** Accepted
- **Date:** 2026-10-17

## Context and Problem Statement

When a platform team designs a `ComputeClass` **Obtainability Ladder** that spans multiple Compute Engine VM generations—for example, preferring 4th-generation VMs (`n4d`, `n4`, `n4a`, `c4`) and falling back to 3rd- or 2nd-generation VMs (`n2d`, `n2`, `e2`) during regional capacity shortages—stateful workloads (`StatefulSet` with `ReadWriteOnce` PersistentVolumeClaims) hit a hard block-storage compatibility wall:

1. **4th-Generation VMs (`n4`, `n4d`, `n4a`, `c4`, `c4a`, `c4d`) only support Google Cloud Hyperdisk** (`hyperdisk-balanced`, `hyperdisk-extreme`, `hyperdisk-throughput`). They cannot attach legacy Persistent Disks (`pd-balanced`, `pd-ssd`, `pd-standard`).
2. **2nd- and 3rd-Generation VMs (`n2`, `n2d`, `e2`, `c2`, `c2d`, `t2d`) only support Persistent Disk** (`pd-balanced`, `pd-ssd`, `pd-standard`) for general RWO block volumes and do not support `hyperdisk-balanced`.

If a `StatefulSet` uses GKE's default `standard-rwo` `StorageClass` (`parameters.type: pd-balanced`), its Pods cannot schedule onto or attach volumes on 4th-generation nodes. Conversely, if a `StatefulSet` hardcodes a `hyperdisk-balanced` `StorageClass`, falling back to 3rd-generation `n2d` or `e2` nodes during a 4th-generation stockout leaves Pods stuck `Pending` because `pd.csi.storage.gke.io` cannot attach `hyperdisk-balanced` to `n2d` or `e2`.

Furthermore, once a `PersistentVolume` (`PV`) is created as `pd-balanced` (or `hyperdisk-balanced`), GCE block volumes cannot morph in place between Persistent Disk and Hyperdisk without snapshot/restore migration. How should a stateful workload use a multi-generation `ComputeClass` so initial fallback, scale-out after capacity recovery, and **Active Migration** (`optimizeRulePriority: true`) all behave safely?

## Decision

For **Demo 02 (`02-stateful-storage`)**, we pair a cross-generation `ComputeClass` (`obtainable-stateful`: Priority #1 = Gen 4 `n4d`, Priority #2 = Gen 3 `n2d` Spot, Priority #3 = Gen 3 `n2` On-Demand) with GKE's built-in **`dynamic-rwo`** `StorageClass` (`provisioner: pd.csi.storage.gke.io`, `volumeBindingMode: WaitForFirstConsumer`, `parameters.type: dynamic`, `hyperdisk-type: hyperdisk-balanced`, `pd-type: pd-balanced`, `use-allowed-disk-topology: "true"`):

1. **Stage 1 (Gen 4 Unobtainable -> Gen 3 Fallback with `pd-balanced`)**:
   - Priority #1 (`machineFamily: n4d`) sets `reservations.affinity: AnyThenFail` (**Fail-Fast Reservation Affinity**). With no `n4d` reservation present, Cluster Autoscaler immediately skips Priority #1 and provisions a Priority #2 Gen 3 node (`machineFamily: n2d`, `spot: true`).
   - `StatefulSet/storage-inspector` (`replicas: 1`, `storageClassName: dynamic-rwo`) schedules `storage-inspector-0` onto the `n2d` node. Because `volumeBindingMode: WaitForFirstConsumer` waits until the node is chosen, `pd.csi.storage.gke.io` inspects the `n2d` node's CSI topology capabilities and dynamically creates a **`pd-balanced`** Persistent Disk, stamping `disk-type.gke.io/pd-balanced: "true"` onto `spec.nodeAffinity` of the bound `PersistentVolume`.
2. **Stage 2 (`make unlock-gen4`: Gen 4 Unlocked + Scale-Out to `replicas: 2`)**:
   - Updating Priority #1 of `ComputeClass/obtainable-stateful` to obtainable Gen 4 `n4d` Spot (`spot: true`) and scaling `StatefulSet/storage-inspector` to `replicas: 2` schedules `storage-inspector-1`, whose unbound PVC (`data-storage-inspector-1`) triggers GKE to provision a Priority #1 **Gen 4 `n4d` Spot** node and causes `dynamic-rwo` to dynamically create a **`hyperdisk-balanced`** volume (`disk-type.gke.io/hyperdisk-balanced: "true"` in `spec.nodeAffinity`).
   - Meanwhile, because `use-allowed-disk-topology: "true"` stamped **PV Disk-Topology Pinning** (`nodeAffinity` requiring `disk-type.gke.io/pd-balanced: "true"`) onto `storage-inspector-0`'s bound `PersistentVolume`, Cluster Autoscaler's **Active Migration** loop respects the PV topology boundary and keeps `storage-inspector-0` safely running on its Gen 3 `n2d` node rather than stranding it on a Hyperdisk-only `n4d` node.

## Consequences

- **Positive:** A single `StatefulSet` manifest with `storageClassName: dynamic-rwo` can provision either `pd-balanced` (on Gen 2/Gen 3 fallback nodes) or `hyperdisk-balanced` (on Gen 4 preferred nodes) without editing `volumeClaimTemplates`.
- **Positive:** **PV Disk-Topology Pinning** (`use-allowed-disk-topology: "true"`) prevents **Active Migration** (`optimizeRulePriority: true`) from breaking already-bound stateful replicas when a `ComputeClass` transitions between Persistent-Disk-only and Hyperdisk-only VM generations.
- **Negative / Operational Trade-off:** Because GCE block volumes cannot convert in place from `pd-balanced` to `hyperdisk-balanced`, existing replicas that provisioned a `pd-balanced` volume during a Gen 4 stockout remain pinned to Gen 2/Gen 3 nodes until their PVC is recreated or migrated via `VolumeSnapshot`.
