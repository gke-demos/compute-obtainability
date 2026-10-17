# Glossary

Canonical domain terms for **Designing for Obtainability on GKE 1.37** (`moficodes/gke-design-for-obtainability`).

| Term | Definition | Avoid |
| :--- | :--- | :--- |
| **Compute Obtainability** | The ability of a GKE cluster to reliably acquire underlying Compute Engine VM capacity during scale-up by spanning multiple machine families, CPU architectures (`x86_64` and `arm64`), and provisioning models (`Reservations`, `Spot`, `On-Demand`). | "Fluid compute" (internal-only term; never use in public docs, code, or manifests). |
| **Obtainability Ladder** | The ordered `spec.priorities` list inside a GKE `ComputeClass` (`cloud.google.com/v1`) that Cluster Autoscaler evaluates from highest to lowest priority when provisioning nodes. | "Fallback chain", "node list". |
| **Architecture Taint Suppression** | Setting `spec.nodePoolConfig.taintConfig.architectureTaintBehavior: NONE` on a `ComputeClass` so GKE does not taint Arm64 nodes (`n4a`, `c4a`, `t2a`) with `kubernetes.io/arch=arm64:NoSchedule`. | "Untainted Arm", "disabling taints". |
| **Fail-Fast Reservation Affinity** | Setting `reservations.affinity: AnyThenFail` on a `ComputeClass` priority rule so Cluster Autoscaler claims an available reservation if present and immediately advances to the next priority rule if none is available, instead of silently falling back to On-Demand VMs of that machine family. | "Best-effort reservation". |
| **Active Migration** | Setting `spec.activeMigration.optimizeRulePriority: true` on a `ComputeClass` so GKE automatically provisions higher-priority nodes when capacity becomes obtainable, cordons and drains lower-priority fallback nodes, and migrates running Pods back up the Obtainability Ladder. | "Node replacement", "rebalancing". |
| **Node Pool Auto-Creation** | Workload-scoped automatic creation and deletion of GKE node pools (`spec.nodePoolAutoCreation.enabled: true`) in GKE Standard and Autopilot clusters without requiring legacy cluster-wide Node Auto-Provisioning (NAP). | "Legacy NAP". |
| **Silicon Inspector** | The zero-build multi-architecture Deployment (`Deployment/silicon-inspector` in namespace `compute-obtainability`) that selects `cloud.google.com/compute-class: obtainable-compute` with zero `tolerations` or `kubernetes.io/arch` selectors and logs/serves its live node, GCE machine type, provisioning model, `uname -m` architecture (`x86_64` vs `aarch64`), and CPU model. | "Test pod", "dummy app". |
