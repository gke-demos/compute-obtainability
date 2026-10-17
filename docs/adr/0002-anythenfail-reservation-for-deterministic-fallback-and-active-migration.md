# ADR-0002: Use `AnyThenFail` Reservation Priority and Priority Promotion for Deterministic Fallback and Active Migration

- **Status**: Accepted
- **Date**: 2026-10-17

## Context

To demonstrate **Compute Obtainability**, **Obtainability Ladder** fallback, and cross-architecture **Active Migration** (`x86_64` -> `aarch64`) on a live GKE 1.37 cluster, we cannot rely on waiting for an unpredictable Compute Engine zonal stockout (`ZONE_RESOURCE_POOL_EXHAUSTED`). We need a deterministic mechanism that exercises the real GKE Cluster Autoscaler and `ComputeClass` reconciliation loop.

Historically, setting `reservations.affinity: AnyBestEffort` on Priority #1 would silently fall back to provisioning expensive On-Demand VMs of the Priority #1 machine family when no reservation was available, bypassing Priority #2. GKE 1.36/1.37 introduced `reservations.affinity: AnyThenFail` (July 2026), which fails the priority rule immediately when no matching reservation is claimable and advances to the next priority rule.

## Decision

We structure the live demo in two deterministic stages against a real GKE 1.37 cluster:

1. **Stage 1 (`manifests/01-computeclass-fallback.yaml` — Initial Fallback to x86_64)**:
   - **Priority #1**: Google Axion Arm64 (`machineFamily: n4a`) with `reservations: { affinity: AnyThenFail }`. Because no `n4a` reservation exists in the test project, GKE evaluates Priority #1, fails fast (`AnyThenFail`) instead of billing On-Demand `n4a`, and falls back to Priority #2.
   - **Priority #2**: AMD EPYC x86_64 Spot (`machineFamily: n4d`, `spot: true`). GKE auto-creates an `n4d` x86_64 Spot node pool and schedules `Deployment/silicon-inspector` on `x86_64`.
   - **Priority #3**: Intel x86_64 On-Demand (`machineFamily: n4`, `spot: false`).
2. **Stage 2 (`manifests/03-computeclass-obtainable-arm.yaml` — Active Migration to Google Axion Arm64)**:
   - We update Priority #1 on `ComputeClass/obtainable-compute` to obtainable Google Axion Arm64 Spot (`machineFamily: n4a`, `spot: true`).
   - Because `activeMigration.optimizeRulePriority: true` and `taintConfig.architectureTaintBehavior: NONE` are enabled, GKE automatically provisions a new `n4a` (`aarch64`) Spot node pool without the `kubernetes.io/arch=arm64:NoSchedule` taint, cordons and drains the Priority #2 `n4d` (`x86_64`) node, and migrates `Deployment/silicon-inspector` live from `x86_64` to `aarch64` with zero changes to the Deployment manifest.

## Consequences

- Exercises 100% real GKE Cluster Autoscaler and Node Pool Auto-Creation behavior (`AnyThenFail` fallback, `architectureTaintBehavior: NONE`, and `optimizeRulePriority: true` Active Migration).
- Reproducible on any GKE 1.37 cluster without needing to artificially exhaust regional Compute Engine capacity.
