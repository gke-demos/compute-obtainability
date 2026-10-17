# Designing for Obtainability on GKE 1.37 (`moficodes/gke-design-for-obtainability`)

Hands-on demo and blog post repository for **Designing for Obtainability** on GKE 1.37+ using Custom `ComputeClass` (`cloud.google.com/v1`), **Architecture Taint Suppression** (`taintConfig.architectureTaintBehavior: NONE`), **Fail-Fast Reservation Affinity** (`reservations.affinity: AnyThenFail`), and **Active Migration** (`activeMigration.optimizeRulePriority: true`) across x86_64 (`n4d`/`n4`) and Google Axion Arm64 (`n4a`/`c4a`).

## Commands

- **Deploy initial fallback state (Priority #1 AnyThenFail -> lands on x86_64 Priority #2)**: `make apply`
- **Promote obtainable Google Axion Arm64 to Priority #1 (triggers Active Migration x86_64 -> aarch64)**: `make unlock-arm`
- **Watch nodes, ComputeClass priorities, and Pod architectures live**: `make watch`
- **Inspect current cluster & silicon status once**: `make status`
- **Run end-to-end verification**: `make verify`
- **Clean up**: `make clean`

## Agent skills

### Issue tracker

Issues and specs are tracked in GitHub Issues (`moficodes/gke-design-for-obtainability`) via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Uses the five default canonical triage labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout (`GLOSSARY.md` at the repo root and ADRs in `docs/adr/`). See `docs/agents/domain.md`.
