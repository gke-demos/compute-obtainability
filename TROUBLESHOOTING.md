# Troubleshooting GKE 1.37 ComputeClass obtainability across architectures and VM generations

This guide covers four operational lessons and edge cases you are likely to encounter when configuring **Compute Obtainability**, **Architecture Taint Suppression**, **Fail-Fast Reservation Affinity**, cross-architecture **Active Migration**, and **Dynamic Block Storage Selection** (`dynamic-rwo`) on GKE 1.37+.

## 1. `architectureTaintBehavior: NONE` vs `cloud.google.com/compute-class` isolation taints

### Symptom

You want unmodified multi-architecture Deployments (`linux/amd64` + `linux/arm64`) to schedule across x86 (`n4d`, `n4`) and Google Axion Arm64 (`n4a`, `c4a`) nodes in a `ComputeClass`, but:

1. Without `architectureTaintBehavior: NONE`, Pods fail to schedule onto Arm64 nodes with `0/N nodes are available: N node(s) had untolerated taint {kubernetes.io/arch: arm64}`.
2. Before enabling `architectureTaintBehavior: NONE`, platform teams worry that removing the `kubernetes.io/arch=arm64:NoSchedule` taint will allow legacy x86-only Pods elsewhere in the cluster to land on Arm64 nodes and fail with `exec format error`.

### Root cause

By default, GKE applies two separate `NoSchedule` taints when **Node Pool Auto-Creation** provisions an Arm64 node pool for a `ComputeClass`:

- `kubernetes.io/arch=arm64:NoSchedule` (architecture taint)
- `cloud.google.com/compute-class=<class-name>:NoSchedule` (ComputeClass isolation taint)

When a Pod selects `nodeSelector: { cloud.google.com/compute-class: obtainable-compute }`, GKE's admission webhook automatically injects a toleration for `cloud.google.com/compute-class=obtainable-compute:NoSchedule`, and leaves `kubernetes.io/arch=arm64:NoSchedule` untolerated unless the Pod spec explicitly declares it.

### Fix and verification

Set `spec.nodePoolConfig.taintConfig.architectureTaintBehavior: NONE` on the `ComputeClass` ([manifests/01-multi-arch/01-computeclass-fallback.yaml](manifests/01-multi-arch/01-computeclass-fallback.yaml), [ADR-0001](docs/adr/0001-architecture-taint-none-over-pod-tolerations.md)):

```yaml
  nodePoolAutoCreation:
    enabled: true
  nodePoolConfig:
    taintConfig:
      architectureTaintBehavior: NONE
```

This suppresses only `kubernetes.io/arch=arm64:NoSchedule`. Every node provisioned for `obtainable-compute` still carries `cloud.google.com/compute-class=obtainable-compute:NoSchedule`:

```bash
kubectl get nodes -l cloud.google.com/compute-class=obtainable-compute \
  -o custom-columns="NAME:.metadata.name,ARCH:.metadata.labels.kubernetes\.io/arch,TAINTS:.spec.taints"
```

```text
NAME                                                  ARCH    TAINTS
gke-ate-cluster-nap-n4a-highcpu-1-spo-2a834e7c-lgkk   arm64   [map[effect:NoSchedule key:cloud.google.com/compute-class value:obtainable-compute]]
```

Workloads that do not select `cloud.google.com/compute-class: obtainable-compute` do not receive the `cloud.google.com/compute-class` toleration and cannot schedule onto these Arm64 nodes.

## 2. `reservations.affinity: AnyThenFail` vs `AnyBestEffort` on Priority #1

### Symptom

You configure Priority #1 of a `ComputeClass` to consume shared or project-level Compute Engine reservations (`reservations.affinity: AnyBestEffort`) and Priority #2 to use lower-cost Spot VMs (`spot: true`). When all reserved VMs in Priority #1 are exhausted, Cluster Autoscaler provisions full-price On-Demand VMs of the Priority #1 machine family instead of advancing to Priority #2 Spot VMs.

### Root cause

In GKE `ComputeClass`, `reservations.affinity: AnyBestEffort` means "consume any matching reservation if available, or fall back to provisioning standard On-Demand instances within this same priority rule." Because On-Demand capacity for Priority #1 succeeds, Cluster Autoscaler considers Priority #1 satisfied and never evaluates Priority #2.

### Fix and verification

Use `reservations.affinity: AnyThenFail` (introduced in GKE 1.36/1.37) whenever a priority rule should only succeed if reserved capacity can actually be claimed ([manifests/01-multi-arch/01-computeclass-fallback.yaml](manifests/01-multi-arch/01-computeclass-fallback.yaml), [manifests/02-stateful-storage/01-computeclass-fallback.yaml](manifests/02-stateful-storage/01-computeclass-fallback.yaml), [ADR-0002](docs/adr/0002-anythenfail-reservation-for-deterministic-fallback-and-active-migration.md)):

```yaml
  priorities:
    - machineFamily: n4a
      reservations:
        affinity: AnyThenFail
    - machineFamily: n4d
      spot: true
    - machineFamily: n4
      spot: false
```

With `AnyThenFail`, when zero unconsumed reservations exist for Priority #1, Cluster Autoscaler immediately marks Priority #1 unclaimable and advances to Priority #2.

## 3. In-place Active Migration timing, `defrag-candidate` taints, and `GKE_METADATA` node labels

### Symptom

After updating `spec.priorities` on an existing `ComputeClass` (`make unlock-arm`), you observe:

1. Cluster Autoscaler takes roughly 2 minutes before initiating Active Migration, even when `consolidationDelayMinutes: 1` is configured.
2. During the transition, the existing `x86_64` fallback node acquires `autoscaling.gke.io/defrag-candidate` and `ToBeDeletedByClusterAutoscaler` taints before Pods move.
3. Inside Pods running on clusters with GKE Workload Identity (`GKE_METADATA`), querying `http://metadata.google.internal/computeMetadata/v1/instance/machine-type` or `instance/scheduling/provisioning-model` returns `404` or empty responses, and `/proc/cpuinfo` on Arm64 (`aarch64`) Linux kernels omits the x86 `model name` field.

### Root cause

1. **In-place Active Migration lifecycle ([ADR-0003](docs/adr/0003-in-place-active-migration-and-defrag-lifecycle.md))**: Modifying `spec.priorities` on a `ComputeClass` with `activeMigration.optimizeRulePriority: true` does not require any Pod scaling event or edit to your Deployment (`metadata.generation` stays `1`). Cluster Autoscaler first waits for `autoscalingPolicy.consolidationDelayMinutes` (`~125s-137s` on `v1.37.0-gke.3503000`), then marks the lower-priority node with `autoscaling.gke.io/defrag-candidate=<epoch>:NoSchedule` and `autoscaling.gke.io/defrag-soft-candidate=<epoch>:PreferNoSchedule` while **Node Pool Auto-Creation** provisions the higher-priority `n4a` node pool. Once the `n4a` nodes reach `Ready` (`+178s`), Cluster Autoscaler cordons and drains the old node with `ToBeDeletedByClusterAutoscaler=<epoch>:NoSchedule`.
2. **Workload Identity metadata filtering and Arm64 `/proc/cpuinfo`**: The GKE Workload Identity metadata server (`GKE_METADATA`) intercepts requests to `169.254.169.254` and only exposes a subset of GCE metadata attributes. In addition, Linux `/proc/cpuinfo` on `aarch64` reports JEDEC implementer and part IDs (`CPU implementer : 0x41`, `CPU part : 0xd8e` for Arm Neoverse-N3 on Google Axion `n4a`, and `0x41`/`0xd4f` for Arm Neoverse-V2 on `c4a`) rather than an x86 `model name` string.

### Fix and verification

Keep `autoscalingPolicy.consolidationDelayMinutes: 1` on `ComputeClass/obtainable-compute` for fast interactive demos, and inspect `configmap/cluster-autoscaler-status` plus node taints during migration:

```bash
kubectl -n kube-system get configmap cluster-autoscaler-status -o jsonpath='{.data.status}'
```

In `manifests/01-multi-arch/02-silicon-inspector.yaml`, the **Silicon Inspector** container handles both `GKE_METADATA` and Arm64 `/proc/cpuinfo` cleanly by:

- Mapping `CPU implementer 0x41` + `CPU part 0xd8e` to `Google Axion (Arm Neoverse-N3 0x41/0xd8e)` (and `0x41/0xd4f` to `Google Axion (Arm Neoverse-V2 0x41/0xd4f)`).
- Falling back to reading `node.kubernetes.io/instance-type` and `cloud.google.com/gke-spot` from `/api/v1/nodes/${NODE_NAME}` when `GKE_METADATA` omits raw GCE instance endpoints.

## 4. Cross-generation stateful storage with `dynamic-rwo`, PV Disk-Topology Pinning, and `podAntiAffinity`

### Symptom

You build a `ComputeClass` **Obtainability Ladder** that spans 4th-generation VMs (`n4d`, `n4`, `n4a`, `c4`) and 3rd- or 2nd-generation fallback VMs (`n2d`, `n2`, `e2`) for a `StatefulSet` with `ReadWriteOnce` volumes, and encounter one of three failure modes:

1. **Pod stuck `Pending` or `AttachVolume.Attach failed` across VM generations**: Using `standard-rwo` (`pd-balanced`) fails when scheduled onto 4th-generation `n4d`/`n4` nodes because Gen 4 VMs only attach Google Cloud Hyperdisk. Conversely, hardcoding a `hyperdisk-balanced` `StorageClass` fails when falling back to 3rd-generation `n2d`/`n2` nodes because Gen 3 VMs do not attach `hyperdisk-balanced`.
2. **Expecting an existing `pd-balanced` replica to live-migrate onto a 4th-generation node when `make unlock-gen4` runs**: After Priority #1 `n4d` Spot is unlocked, `storage-inspector-0` remains on its 3rd-generation `n2d-standard-2` node rather than migrating onto `n4d-highcpu-2`.
3. **Second `StatefulSet` replica schedules onto the existing 3rd-generation node instead of provisioning a Priority #1 4th-generation node**: If `podAntiAffinity` is omitted and the existing `n2d-standard-2` node has enough unallocated CPU and memory for a second Pod, the scheduler places `storage-inspector-1` on the already-running `n2d` node without invoking Cluster Autoscaler.

### Root cause

1. **VM generation disk-type boundary ([ADR-0004](docs/adr/0004-dynamic-rwo-and-pv-topology-pinning-across-vm-generations.md))**: GKE's pre-installed `StorageClass/dynamic-rwo` (`provisioner: pd.csi.storage.gke.io`, `volumeBindingMode: WaitForFirstConsumer`, `parameters.type: dynamic`, `hyperdisk-type: hyperdisk-balanced`, `pd-type: pd-balanced`, `use-allowed-disk-topology: "true"`) solves initial placement by waiting until a node is chosen and then provisioning `hyperdisk-balanced` for Gen 4 VMs or `pd-balanced` for Gen 2/Gen 3 VMs.
2. **PV Disk-Topology Pinning (`disk-type.gke.io/pd-balanced` vs `disk-type.gke.io/hyperdisk-balanced`)**: Because GCE block volumes cannot convert in place between Persistent Disk and Hyperdisk, `use-allowed-disk-topology: "true"` stamps a `nodeAffinity` requirement onto the dynamically created `PersistentVolume` (`disk-type.gke.io/pd-balanced: "true"` on Gen 3 or `disk-type.gke.io/hyperdisk-balanced: "true"` on Gen 4). Notice also that `pd.csi.storage.gke.io` does not populate `spec.csi.volumeAttributes.type` when `parameters.type: dynamic` is used; the resolved GCE disk type is recorded in the PV's `spec.nodeAffinity` selector (`disk-type.gke.io/<disk-type>`). When Priority #1 `n4d` becomes obtainable, Cluster Autoscaler's **Active Migration** (`optimizeRulePriority: true`) checks whether `storage-inspector-0` can schedule onto `n4d`, sees the `disk-type.gke.io/pd-balanced` PV node affinity, and keeps `storage-inspector-0` safely running on its Gen 3 `n2d` node.
3. **Scheduler bin-packing vs scale-out**: Kubernetes `kube-scheduler` always prefers scheduling a `Pending` Pod onto an existing `Ready` node that satisfies its constraints before leaving the Pod `Unschedulable` for Cluster Autoscaler to trigger scale-up.

### Fix and verification

In `manifests/02-stateful-storage/02-storage-inspector.yaml`, configure `storageClassName: dynamic-rwo` on `volumeClaimTemplates` and add a hostname `podAntiAffinity` rule so each stateful replica lands on a separate node and evaluates the highest obtainable priority rule in `ComputeClass/obtainable-stateful`:

```yaml
      nodeSelector:
        cloud.google.com/compute-class: obtainable-stateful
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: storage-inspector
              topologyKey: kubernetes.io/hostname
```

Verify the resolved disk type and **PV Disk-Topology Pinning** on each bound `PersistentVolume` by inspecting `spec.nodeAffinity`:

```bash
kubectl get pv -o custom-columns="PV:.metadata.name,CLAIM:.spec.claimRef.name,NODE-AFFINITY:.spec.nodeAffinity.required.nodeSelectorTerms[*].matchExpressions"
```

```text
PV                                         CLAIM                                           NODE-AFFINITY
pvc-94f9c835-142d-40fc-881e-9c4367631f05    data-storage-inspector-0                        [map[key:topology.gke.io/zone operator:In values:[us-central1-a]] map[key:disk-type.gke.io/pd-balanced operator:In values:[true]]]
pvc-e511fbcf-0661-4687-bc6b-990b2de453a4   data-storage-inspector-1                        [map[key:topology.gke.io/zone operator:In values:[us-central1-a]] map[key:disk-type.gke.io/hyperdisk-balanced operator:In values:[true]]]
```
