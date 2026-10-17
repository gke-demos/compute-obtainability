# Designing for Obtainability on GKE 1.37 (`moficodes/gke-design-for-obtainability`)

Hands-on demo and blog post repository for **Designing for Obtainability** on GKE 1.37+ using Custom `ComputeClass` (`cloud.google.com/v1`), **Architecture Taint Suppression** (`taintConfig.architectureTaintBehavior: NONE`), **Fail-Fast Reservation Affinity** (`reservations.affinity: AnyThenFail`), **Active Migration** (`activeMigration.optimizeRulePriority: true`), **Dynamic Block Storage Selection** (`StorageClass/dynamic-rwo`), and **PV Disk-Topology Pinning** (`use-allowed-disk-topology: "true"`).

## Commands

### Demo 01: Multi-Architecture Silicon Obtainability (`01-multi-arch`)

- **Deploy initial fallback state (Priority #1 AnyThenFail -> lands on x86_64 Priority #2)**: `make apply` (or `make apply-multi-arch`)
- **Promote obtainable Google Axion Arm64 to Priority #1 (triggers Active Migration x86_64 -> aarch64)**: `make unlock-arm`
- **Watch nodes, ComputeClass priorities, and Pod architectures live**: `make watch` (or `make watch-multi-arch`)
- **Inspect current cluster & silicon status once**: `make status` (or `make status-multi-arch`)
- **Run end-to-end verification**: `make verify` (or `make verify-multi-arch`)

### Demo 02: Cross-Generation Stateful Obtainability (`02-stateful-storage`)

- **Deploy initial Stage 1 fallback state (Priority #1 Gen 4 n4d AnyThenFail -> lands on Priority #2 Gen 3 n2d Spot with `pd-balanced`)**: `make apply-stateful`
- **Promote obtainable Gen 4 n4d Spot to Priority #1 and scale StatefulSet to 2 replicas (`hyperdisk-balanced` on Gen 4 + PV Disk-Topology Pinning on Gen 3)**: `make unlock-gen4`
- **Watch ComputeClass, StorageClass/dynamic-rwo, nodes, PVCs/PVs, and StatefulSet replicas live**: `make watch-stateful`
- **Inspect current stateful storage status once**: `make status-stateful`
- **Stream Storage Inspector Pod logs**: `make logs-stateful`
- **Run end-to-end stateful verification**: `make verify-stateful`

### Cleanup & Docs Verification

- **Clean up both demos**: `make clean` (`make clean-multi-arch` / `make clean-stateful`)
- **Verify documentation and demo media assets**: `./hack/test-docs.sh`

## Agent skills

### Issue tracker

Issues and specs are tracked in GitHub Issues (`moficodes/gke-design-for-obtainability`) via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Uses the five default canonical triage labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout (`GLOSSARY.md` at the repo root and ADRs in `docs/adr/`). See `docs/agents/domain.md`.
