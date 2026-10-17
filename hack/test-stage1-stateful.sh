#!/usr/bin/env bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}"
NAMESPACE="obtainability-stateful"
COMPUTE_CLASS="obtainable-stateful"
STATEFULSET="storage-inspector"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_PREFIX="stage1-stateful"
# shellcheck source=hack/lib.sh
source "${SCRIPT_DIR}/lib.sh"

CC_MANIFEST="${REPO_ROOT}/manifests/02-stateful-storage/01-computeclass-fallback.yaml"
APP_MANIFEST="${REPO_ROOT}/manifests/02-stateful-storage/02-storage-inspector.yaml"

log "Step 1: Checking Demo 02 Stage 1 manifests exist..."
[[ -f "${CC_MANIFEST}" ]] || fail "Missing manifest: ${CC_MANIFEST}"
[[ -f "${APP_MANIFEST}" ]] || fail "Missing manifest: ${APP_MANIFEST}"
pass "Both Demo 02 Stage 1 manifests exist."

log "Step 2: Checking public terminology hygiene (no banned internal terms)..."
check_no_banned_terms "${REPO_ROOT}/manifests/"
pass "Manifests use canonical Compute Obtainability terminology."

log "Step 3: Validating ComputeClass/obtainable-stateful and Storage Inspector StatefulSet structure..."
assert_stateful_computeclass_schema "${CC_MANIFEST}" "stage1"
python3 - "${APP_MANIFEST}" <<'PY'
import sys
import yaml

app_path = sys.argv[1]

with open(app_path, "r", encoding="utf-8") as f:
    app_docs = [d for d in yaml.safe_load_all(f) if d]

kinds = [d.get("kind") for d in app_docs]
for required_kind in ("Namespace", "ServiceAccount", "ClusterRole", "ClusterRoleBinding", "Service", "StatefulSet"):
    assert required_kind in kinds, f"02-storage-inspector.yaml must define {required_kind}"

sts = next(d for d in app_docs if d.get("kind") == "StatefulSet")
assert sts.get("metadata", {}).get("name") == "storage-inspector", "StatefulSet name must be storage-inspector"
assert sts.get("metadata", {}).get("namespace") == "obtainability-stateful", "StatefulSet namespace must be obtainability-stateful"

s_spec = sts.get("spec", {})
assert s_spec.get("replicas") == 1, f"Expected 1 replica in Stage 1, got {s_spec.get('replicas')}"
assert s_spec.get("podManagementPolicy") == "Parallel", "StatefulSet podManagementPolicy must be Parallel"

pod_spec = s_spec.get("template", {}).get("spec", {})
node_selector = pod_spec.get("nodeSelector", {})
assert node_selector == {"cloud.google.com/compute-class": "obtainable-stateful"}, (
    f"Pod spec nodeSelector must select cloud.google.com/compute-class: obtainable-stateful, found: {node_selector}"
)

anti_aff = (
    pod_spec.get("affinity", {})
    .get("podAntiAffinity", {})
    .get("requiredDuringSchedulingIgnoredDuringExecution", [])
)
assert any(t.get("topologyKey") == "kubernetes.io/hostname" for t in anti_aff), (
    "StatefulSet Pod template must define required podAntiAffinity on kubernetes.io/hostname so replicas spread across nodes"
)

vcts = s_spec.get("volumeClaimTemplates", [])
assert len(vcts) == 1, f"Expected 1 volumeClaimTemplate, got {len(vcts)}"
vct = vcts[0]
assert vct.get("metadata", {}).get("name") == "data", "volumeClaimTemplate name must be data"
assert vct.get("spec", {}).get("storageClassName") == "dynamic-rwo", "volumeClaimTemplate storageClassName must be dynamic-rwo"
assert vct.get("spec", {}).get("accessModes") == ["ReadWriteOnce"], "volumeClaimTemplate accessModes must be ['ReadWriteOnce']"
PY
pass "ComputeClass/obtainable-stateful and StatefulSet/storage-inspector schema verified."

log "Step 4: Verifying StorageClass/dynamic-rwo on ${KUBE_CONTEXT}..."
SC_JSON="$(kubectl --context="${KUBE_CONTEXT}" get storageclass dynamic-rwo -o json)"
python3 - "${SC_JSON}" <<'PY'
import json
import sys

sc = json.loads(sys.argv[1])
assert sc.get("provisioner") == "pd.csi.storage.gke.io", f"Unexpected provisioner: {sc.get('provisioner')}"
assert sc.get("volumeBindingMode") == "WaitForFirstConsumer", f"Expected WaitForFirstConsumer, got {sc.get('volumeBindingMode')}"
params = sc.get("parameters", {})
assert params.get("type") == "dynamic", f"Expected parameters.type == 'dynamic', got {params.get('type')}"
assert params.get("hyperdisk-type") == "hyperdisk-balanced", f"Expected hyperdisk-type == 'hyperdisk-balanced', got {params.get('hyperdisk-type')}"
assert params.get("pd-type") == "pd-balanced", f"Expected pd-type == 'pd-balanced', got {params.get('pd-type')}"
assert params.get("use-allowed-disk-topology") == "true", f"Expected use-allowed-disk-topology == 'true', got {params.get('use-allowed-disk-topology')}"
PY
pass "StorageClass/dynamic-rwo verified on cluster (type=dynamic, hyperdisk-balanced, pd-balanced, WaitForFirstConsumer)."

log "Step 5: Running server-side dry-run validation against ${KUBE_CONTEXT}..."
kubectl --context="${KUBE_CONTEXT}" apply --dry-run=server -f "${CC_MANIFEST}" >/dev/null
kubectl --context="${KUBE_CONTEXT}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl --context="${KUBE_CONTEXT}" apply -f - >/dev/null
kubectl --context="${KUBE_CONTEXT}" apply --dry-run=server -f "${APP_MANIFEST}" >/dev/null
pass "Both manifests passed kubectl apply --dry-run=server."

log "Step 6: Applying Demo 02 Stage 1 manifests to ${KUBE_CONTEXT}..."
kubectl --context="${KUBE_CONTEXT}" apply -f "${CC_MANIFEST}"
kubectl --context="${KUBE_CONTEXT}" apply -f "${APP_MANIFEST}"

log "Step 7: Waiting for ComputeClass/${COMPUTE_CLASS} to report Health=True..."
kubectl --context="${KUBE_CONTEXT}" wait --for=condition=Health=True "computeclass/${COMPUTE_CLASS}" --timeout=120s
pass "ComputeClass/${COMPUTE_CLASS} is Healthy."

log "Step 8: Waiting for StatefulSet/${STATEFULSET} (1/1 Ready) and Priority #2 Gen 3 (n2d Spot) node auto-creation..."
kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" rollout status "statefulset/${STATEFULSET}" --timeout=600s
pass "StatefulSet/${STATEFULSET} reached 1/1 Ready (storage-inspector-0)."

log "Step 9: Verifying auto-created node matches Priority #2 (Gen 3 n2d Spot, skipping Priority #1 n4d AnyThenFail)..."
POD_NODE="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod storage-inspector-0 -o jsonpath='{.spec.nodeName}')"
NODE_JSON="$(kubectl --context="${KUBE_CONTEXT}" get node "${POD_NODE}" -o json)"
python3 - "${NODE_JSON}" <<'PY'
import json
import sys

node = json.loads(sys.argv[1])
name = node["metadata"]["name"]
labels = node["metadata"].get("labels", {})
cc_label = labels.get("cloud.google.com/compute-class")
instance_type = labels.get("node.kubernetes.io/instance-type", "")
spot = labels.get("cloud.google.com/gke-spot") or labels.get("cloud.google.com/gke-provisioning")
print(f"  Verified node {name}: compute-class={cc_label}, instance-type={instance_type}, spot={spot}")
assert cc_label == "obtainable-stateful", f"Expected compute-class=obtainable-stateful, got {cc_label}"
assert instance_type.startswith("n2d-"), f"Expected Priority #2 Gen 3 n2d-* machine type, got {instance_type} on {name}"
assert spot in ("true", "spot"), f"Expected Spot provisioning on {name}, got {spot}"
PY
pass "Cluster Autoscaler skipped unclaimable Priority #1 (n4d AnyThenFail) and provisioned Priority #2 Gen 3 (n2d Spot)."

log "Step 10: Verifying PVC/data-storage-inspector-0 bound to a PersistentVolume with pd-balanced topology and GCE diskType..."
PVC_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pvc data-storage-inspector-0 -o json)"
PV_NAME="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pvc data-storage-inspector-0 -o jsonpath='{.spec.volumeName}')"
PV_JSON="$(kubectl --context="${KUBE_CONTEXT}" get pv "${PV_NAME}" -o json)"
python3 - "${PVC_JSON}" "${PV_JSON}" <<'PY'
import json
import re
import sys

pvc = json.loads(sys.argv[1])
pv = json.loads(sys.argv[2])

assert pvc.get("status", {}).get("phase") == "Bound", f"Expected PVC Bound, got {pvc.get('status', {}).get('phase')}"
assert pvc.get("spec", {}).get("storageClassName") == "dynamic-rwo", f"Expected storageClassName=dynamic-rwo, got {pvc.get('spec', {}).get('storageClassName')}"

node_aff = json.dumps(pv.get("spec", {}).get("nodeAffinity", {}))
m = re.search(r"disk-type\.gke\.io/(pd-[a-z0-9-]+|hyperdisk-[a-z0-9-]+)", node_aff)
disk_type = pv.get("spec", {}).get("csi", {}).get("volumeAttributes", {}).get("type") or (m.group(1) if m else None)
print(f"  Verified PV {pv['metadata']['name']}: resolved disk_type={disk_type} (from PV nodeAffinity / volumeAttributes)")
assert disk_type == "pd-balanced", f"Expected resolved disk_type == 'pd-balanced' on Gen 3 n2d node, got {disk_type}"
assert "disk-type.gke.io/pd-balanced" in node_aff, f"Expected PV Disk-Topology Pinning (disk-type.gke.io/pd-balanced) in PV nodeAffinity, got {node_aff}"
PY
pass "StorageClass/dynamic-rwo dynamically provisioned pd-balanced with PV Disk-Topology Pinning (disk-type.gke.io/pd-balanced: true) on Gen 3 n2d."

log "Step 11: Verifying storage-inspector-0 writes /tmp/storage-report, /data/replica-history.log, and stdout logs..."
verify_pod_storage_report "${KUBE_CONTEXT}" "${NAMESPACE}" "storage-inspector-0" "Gen3" "n2d-" "spot" "data-storage-inspector-0" "pd-balanced"
HISTORY_LOG="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" exec storage-inspector-0 -- cat /data/replica-history.log)"
echo "--- storage-inspector-0 /data/replica-history.log ---"
echo "${HISTORY_LOG}"
grep -q "pod=storage-inspector-0" <<<"${HISTORY_LOG}" || fail "/data/replica-history.log missing pod=storage-inspector-0"
pass "Demo 02 Stage 1 verified: storage-inspector-0 Running on Gen 3 n2d Spot with dynamically selected pd-balanced volume!"
