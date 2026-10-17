#!/usr/bin/env bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-gke_mofilabs_us-central1-a_ate-cluster}"
NAMESPACE="compute-obtainability"
COMPUTE_CLASS="obtainable-compute"
DEPLOYMENT="silicon-inspector"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_PREFIX="stage1-test"
# shellcheck source=hack/lib.sh
source "${SCRIPT_DIR}/lib.sh"

CC_MANIFEST="${REPO_ROOT}/manifests/01-multi-arch/01-computeclass-fallback.yaml"
APP_MANIFEST="${REPO_ROOT}/manifests/01-multi-arch/02-silicon-inspector.yaml"

log "Step 1: Checking Stage 1 manifests exist..."
[[ -f "${CC_MANIFEST}" ]] || fail "Missing manifest: ${CC_MANIFEST}"
[[ -f "${APP_MANIFEST}" ]] || fail "Missing manifest: ${APP_MANIFEST}"
pass "Both Stage 1 manifests exist."

log "Step 2: Checking public terminology hygiene (no banned internal terms)..."
check_no_banned_terms "${REPO_ROOT}/manifests/"
pass "Manifests use canonical Compute Obtainability terminology."

log "Step 3: Validating ComputeClass and Silicon Inspector manifest structure..."
assert_computeclass_schema "${CC_MANIFEST}" "stage1"
python3 - "${APP_MANIFEST}" <<'PY'
import sys
import yaml

app_path = sys.argv[1]

with open(app_path, "r", encoding="utf-8") as f:
    app_docs = [d for d in yaml.safe_load_all(f) if d]

kinds = [d.get("kind") for d in app_docs]
assert "Namespace" in kinds, "02-silicon-inspector.yaml must define Namespace compute-obtainability"
assert "Deployment" in kinds, "02-silicon-inspector.yaml must define Deployment silicon-inspector"

deploy = next(d for d in app_docs if d.get("kind") == "Deployment")
assert deploy.get("metadata", {}).get("name") == "silicon-inspector", "Deployment name must be silicon-inspector"
assert deploy.get("metadata", {}).get("namespace") == "compute-obtainability", "Deployment namespace must be compute-obtainability"

d_spec = deploy.get("spec", {})
assert d_spec.get("replicas") == 2, f"Expected 2 replicas, got {d_spec.get('replicas')}"

pod_spec = d_spec.get("template", {}).get("spec", {})
assert "tolerations" not in pod_spec or not pod_spec["tolerations"], (
    f"Pod spec must have zero tolerations (ADR-0001), found: {pod_spec.get('tolerations')}"
)
node_selector = pod_spec.get("nodeSelector", {})
assert node_selector == {"cloud.google.com/compute-class": "obtainable-compute"}, (
    f"Pod spec nodeSelector must only select cloud.google.com/compute-class: obtainable-compute, found: {node_selector}"
)
assert "kubernetes.io/arch" not in str(pod_spec), "Pod spec must not contain kubernetes.io/arch selector"
PY
pass "Manifest schema, Obtainability Ladder rules, and ADR-0001 zero-toleration invariants verified."

log "Step 4: Running server-side dry-run validation against ${KUBE_CONTEXT}..."
kubectl --context="${KUBE_CONTEXT}" apply --dry-run=server -f "${CC_MANIFEST}" >/dev/null
# Ensure namespace exists or dry-run namespace first so Deployment server dry-run succeeds
kubectl --context="${KUBE_CONTEXT}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl --context="${KUBE_CONTEXT}" apply -f - >/dev/null
kubectl --context="${KUBE_CONTEXT}" apply --dry-run=server -f "${APP_MANIFEST}" >/dev/null
pass "Both manifests passed kubectl apply --dry-run=server."

log "Step 5: Applying Stage 1 manifests to ${KUBE_CONTEXT}..."
kubectl --context="${KUBE_CONTEXT}" apply -f "${CC_MANIFEST}"
kubectl --context="${KUBE_CONTEXT}" apply -f "${APP_MANIFEST}"

log "Step 6: Waiting for ComputeClass/${COMPUTE_CLASS} to report Health=True..."
kubectl --context="${KUBE_CONTEXT}" wait --for=condition=Health=True "computeclass/${COMPUTE_CLASS}" --timeout=120s
pass "ComputeClass/${COMPUTE_CLASS} is Healthy."

log "Step 7: Waiting for Deployment/${DEPLOYMENT} (2/2 replicas) and Priority #2 (n4d Spot amd64) node auto-creation..."
kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout=600s
pass "Deployment/${DEPLOYMENT} reached 2/2 Ready replicas."

log "Step 8: Verifying auto-created node matches Priority #2 (n4d Spot amd64, skipping Priority #1 AnyThenFail)..."
NODES_JSON="$(kubectl --context="${KUBE_CONTEXT}" get nodes -l "cloud.google.com/compute-class=${COMPUTE_CLASS}" -o json)"
python3 - "${NODES_JSON}" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
items = data.get("items", [])
assert len(items) >= 1, "Expected at least 1 node labeled cloud.google.com/compute-class=obtainable-compute"

for node in items:
    name = node["metadata"]["name"]
    labels = node["metadata"].get("labels", {})
    arch = labels.get("kubernetes.io/arch")
    instance_type = labels.get("node.kubernetes.io/instance-type", "")
    spot = labels.get("cloud.google.com/gke-spot") or labels.get("cloud.google.com/gke-provisioning")
    print(f"  Verified node {name}: arch={arch}, instance-type={instance_type}, spot={spot}")
    assert arch == "amd64", f"Expected Stage 1 node arch=amd64, got {arch} on {name}"
    assert instance_type.startswith("n4d-"), f"Expected Priority #2 n4d-* machine type, got {instance_type} on {name}"
    assert spot in ("true", "spot"), f"Expected Spot provisioning on {name}, got {spot}"
PY
pass "Cluster Autoscaler skipped unclaimable Priority #1 (n4a AnyThenFail) and provisioned Priority #2 (n4d Spot amd64)."

log "Step 9: Verifying Silicon Inspector Pods report ARCH=x86_64, MACHINE_TYPE=n4d-*, and PROVISIONING=spot..."
verify_pods_silicon_report "${KUBE_CONTEXT}" "${NAMESPACE}" "x86_64" "n4d-" "spot"
pass "All 2 Silicon Inspector Pods verified on x86_64 (n4d Spot)."
