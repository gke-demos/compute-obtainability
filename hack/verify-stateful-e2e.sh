#!/usr/bin/env bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}"
NAMESPACE="obtainability-stateful"
COMPUTE_CLASS="obtainable-stateful"
STATEFULSET="storage-inspector"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_PREFIX="verify-stateful"
LOG_TIMESTAMP="true"
# shellcheck source=hack/lib.sh
source "${SCRIPT_DIR}/lib.sh"

STAGE1_CC="${REPO_ROOT}/manifests/02-stateful-storage/01-computeclass-fallback.yaml"
APP_MANIFEST="${REPO_ROOT}/manifests/02-stateful-storage/02-storage-inspector.yaml"
STAGE2_CC="${REPO_ROOT}/manifests/02-stateful-storage/03-computeclass-obtainable-gen4.yaml"
MAKEFILE_PATH="${REPO_ROOT}/Makefile"
WATCH_STATEFUL_SCRIPT="${REPO_ROOT}/hack/watch-stateful.sh"

log "Step 1: Checking required Demo 02 Stage 1 & Stage 2 artifacts exist..."
[[ -f "${STAGE1_CC}" ]] || fail "Missing Stage 1 ComputeClass manifest: ${STAGE1_CC}"
[[ -f "${APP_MANIFEST}" ]] || fail "Missing Storage Inspector manifest: ${APP_MANIFEST}"
[[ -f "${STAGE2_CC}" ]] || fail "Missing Stage 2 ComputeClass manifest: ${STAGE2_CC}"
[[ -f "${MAKEFILE_PATH}" ]] || fail "Missing Makefile: ${MAKEFILE_PATH}"
[[ -x "${WATCH_STATEFUL_SCRIPT}" ]] || fail "Missing or non-executable stateful watch script: ${WATCH_STATEFUL_SCRIPT}"
pass "All required Demo 02 manifests, Makefile, and hack/watch-stateful.sh exist."

log "Step 2: Checking public terminology hygiene across manifests, Makefile, and hack/..."
check_no_banned_terms "${REPO_ROOT}/manifests/" "${MAKEFILE_PATH}" "${WATCH_STATEFUL_SCRIPT}" "${STAGE2_CC}" "${REPO_ROOT}/hack/verify-stateful-e2e.sh"
pass "All files use canonical Compute Obtainability terminology."

log "Step 3: Validating Stage 2 ComputeClass manifest (manifests/02-stateful-storage/03-computeclass-obtainable-gen4.yaml) and Makefile targets..."
assert_stateful_computeclass_schema "${STAGE2_CC}" "stage2"
python3 - "${MAKEFILE_PATH}" <<'PY'
import sys

mk_path = sys.argv[1]
with open(mk_path, "r", encoding="utf-8") as f:
    mk_text = f.read()

required_targets = (
    "apply-multi-arch:",
    "unlock-arm:",
    "watch-multi-arch:",
    "status-multi-arch:",
    "logs-multi-arch:",
    "verify-multi-arch:",
    "clean-multi-arch:",
    "apply-stateful:",
    "unlock-gen4:",
    "watch-stateful:",
    "status-stateful:",
    "logs-stateful:",
    "verify-stateful:",
    "clean-stateful:",
    "clean:",
)
for target in required_targets:
    assert target in mk_text, f"Makefile missing required target {target}"
PY
kubectl --context="${KUBE_CONTEXT}" apply --dry-run=server -f "${STAGE2_CC}" >/dev/null
pass "Stage 2 ComputeClass schema, dry-run validation, and Makefile targets verified."

log "Step 4: Ensuring Demo 02 Stage 1 (Gen 3 n2d Spot fallback with pd-balanced) is active on ${KUBE_CONTEXT}..."
NeedStage1Reset="false"
CURRENT_P1_RES="$(kubectl --context="${KUBE_CONTEXT}" get computeclass "${COMPUTE_CLASS}" -o jsonpath='{.spec.priorities[0].reservations.affinity}' 2>/dev/null || true)"
CURRENT_REPLICAS="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get statefulset "${STATEFULSET}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
POD0_PHASE="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod storage-inspector-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)"
POD0_NODE="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod storage-inspector-0 -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
POD0_ITYPE=""
if [[ -n "${POD0_NODE}" ]]; then
  POD0_ITYPE="$(kubectl --context="${KUBE_CONTEXT}" get node "${POD0_NODE}" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || true)"
fi
ALL_STATEFUL_ITYPES="$(kubectl --context="${KUBE_CONTEXT}" get nodes -l "cloud.google.com/compute-class=${COMPUTE_CLASS}" -o jsonpath='{.items[*].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || true)"

if [[ "${CURRENT_P1_RES}" != "AnyThenFail" ]] || [[ "${CURRENT_REPLICAS}" != "1" ]] || [[ "${POD0_PHASE}" != "Running" ]] || [[ "${POD0_ITYPE}" != n2d-* ]] || [[ "${ALL_STATEFUL_ITYPES}" == *"n4d-"* ]]; then
  NeedStage1Reset="true"
fi

if [[ "${NeedStage1Reset}" == "true" ]]; then
  log "Cluster is not in pure Demo 02 Stage 1 state; resetting to Stage 1..."
  kubectl --context="${KUBE_CONTEXT}" apply -f "${STAGE1_CC}" >/dev/null
  kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" scale statefulset "${STATEFULSET}" --replicas=1 >/dev/null 2>&1 || true
  kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" wait --for=delete pod/storage-inspector-1 --timeout=60s >/dev/null 2>&1 || true
  kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" delete pvc data-storage-inspector-1 --ignore-not-found=true >/dev/null 2>&1 || true
  for _ in {1..45}; do
    N4D_NODES="$(kubectl --context="${KUBE_CONTEXT}" get nodes -l "cloud.google.com/compute-class=${COMPUTE_CLASS}" -o jsonpath='{range .items[*]}{.metadata.name}:{.metadata.labels.node\.kubernetes\.io/instance-type}{"\n"}{end}' 2>/dev/null | grep ':n4d-' | cut -d: -f1 || true)"
    if [[ -z "${N4D_NODES}" ]]; then
      break
    fi
    log "Waiting for Cluster Autoscaler to consolidate empty Gen 4 n4d node (${N4D_NODES})..."
    sleep 6
  done
  KUBE_CONTEXT="${KUBE_CONTEXT}" "${REPO_ROOT}/hack/test-stage1-stateful.sh"
else
  log "Cluster already has Demo 02 Stage 1 deployed on Gen 3 n2d; verifying Stage 1 state..."
  KUBE_CONTEXT="${KUBE_CONTEXT}" "${REPO_ROOT}/hack/test-stage1-stateful.sh"
fi

log "Step 5: Capturing 'make status-stateful' in Stage 1 (Gen 3 n2d Spot with pd-balanced)..."
STAGE1_STATUS="$(make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" status-stateful)"
echo "${STAGE1_STATUS}"
STAGE1_PLAIN="$(printf "%s" "${STAGE1_STATUS}" | sed 's/\x1b\[[0-9;]*m//g')"
python3 - "${STAGE1_PLAIN}" <<'PY'
import sys

text = sys.argv[1]
for idx, line in enumerate(text.splitlines(), start=1):
    assert len(line) <= 134, f"Line {idx} exceeds 134 chars ({len(line)} chars): {line}"

for token in (
    "ComputeClass/obtainable-stateful",
    "StorageClass/dynamic-rwo",
    "AnyThenFail",
    "n2d-",
    "Gen3",
    "data-storage-inspector-0",
    "pd-balanced",
    "disk-type.gke.io/pd-balanced",
    "storage-inspector-0",
):
    assert token in text, f"Stage 1 status-stateful output missing expected token: {token}"
PY
pass "Stage 1 'make status-stateful' output and line widths (<= 134 chars) verified."

STAGE1_POD0_NODE="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod storage-inspector-0 -o jsonpath='{.spec.nodeName}')"
STAGE1_POD0_UID="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod storage-inspector-0 -o jsonpath='{.metadata.uid}')"
STAGE1_PV0_NAME="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pvc data-storage-inspector-0 -o jsonpath='{.spec.volumeName}')"
log "Recorded Stage 1 baseline: storage-inspector-0 node=${STAGE1_POD0_NODE}, uid=${STAGE1_POD0_UID}, pv=${STAGE1_PV0_NAME}"

log "Step 6: Running 'make unlock-gen4' to promote Gen 4 n4d Spot to Priority #1 and scale StatefulSet/storage-inspector to 2 replicas..."
T_UNLOCK="$(date +%s)"
make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" unlock-gen4

P1_FAMILY="$(kubectl --context="${KUBE_CONTEXT}" get computeclass "${COMPUTE_CLASS}" -o jsonpath='{.spec.priorities[0].machineFamily}')"
P1_SPOT="$(kubectl --context="${KUBE_CONTEXT}" get computeclass "${COMPUTE_CLASS}" -o jsonpath='{.spec.priorities[0].spot}')"
STS_REPLICAS="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get statefulset "${STATEFULSET}" -o jsonpath='{.spec.replicas}')"
[[ "${P1_FAMILY}" == "n4d" && "${P1_SPOT}" == "true" ]] || fail "Expected Priority #1 machineFamily=n4d spot=true, got family=${P1_FAMILY} spot=${P1_SPOT}"
[[ "${STS_REPLICAS}" == "2" ]] || fail "Expected StatefulSet replicas=2 after make unlock-gen4, got ${STS_REPLICAS}"
pass "ComputeClass/${COMPUTE_CLASS} updated (Priority #1: n4d spot=true) and StatefulSet/${STATEFULSET} scaled to 2 replicas."

log "Step 7: Observing GKE Node Pool Auto-Creation (Gen 4 n4d Spot), Dynamic Block Storage Selection (hyperdisk-balanced for storage-inspector-1), and PV Disk-Topology Pinning (storage-inspector-0 stays on Gen 3 n2d)..."
T_N4D_REGISTERED=""
T_N4D_READY=""
T_PVC1_BOUND=""
T_POD1_READY=""
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-900}"

while true; do
  NOW="$(date +%s)"
  ELAPSED=$((NOW - T_UNLOCK))
  if (( ELAPSED > MAX_WAIT_SECONDS )); then
    fail "Timed out after ${MAX_WAIT_SECONDS}s waiting for Gen 4 n4d Spot node and storage-inspector-1 with hyperdisk-balanced"
  fi

  NODES_JSON="$(kubectl --context="${KUBE_CONTEXT}" get nodes -l "cloud.google.com/compute-class=${COMPUTE_CLASS}" -o json)"
  PODS_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=storage-inspector -o json)"
  PVCS_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pvc -o json)"
  PVS_JSON="$(kubectl --context="${KUBE_CONTEXT}" get pv -o json)"
  CA_STATUS="$(kubectl --context="${KUBE_CONTEXT}" -n kube-system get configmap cluster-autoscaler-status -o jsonpath='{.data.status}' 2>/dev/null || true)"

  STATE_SUMMARY="$(python3 - "${NODES_JSON}" "${PODS_JSON}" "${PVCS_JSON}" "${PVS_JSON}" "${CA_STATUS}" <<'PY'
import json
import re
import sys
import yaml

nodes = json.loads(sys.argv[1]).get("items", [])
pods = json.loads(sys.argv[2]).get("items", [])
pvcs = json.loads(sys.argv[3]).get("items", [])
pvs = {pv["metadata"]["name"]: pv for pv in json.loads(sys.argv[4]).get("items", [])}
ca_raw = sys.argv[5]

ca_info = ""
if ca_raw:
    try:
        ca_doc = yaml.safe_load(ca_raw) or {}
        su = ca_doc.get("clusterWide", {}).get("scaleUp", {}).get("status", "")
        sd = ca_doc.get("clusterWide", {}).get("scaleDown", {}).get("status", "")
        ca_info = f"CA[su={su},sd={sd}]"
    except Exception:
        ca_info = "CA[parse-err]"

n4d_count = 0
n4d_ready = 0
node_itype_map = {}
node_parts = []
for n in nodes:
    name = n["metadata"]["name"]
    labels = n["metadata"].get("labels", {})
    itype = labels.get("node.kubernetes.io/instance-type", "unknown")
    unsched = n["spec"].get("unschedulable", False)
    conds = {c["type"]: c["status"] for c in n.get("status", {}).get("conditions", [])}
    ready = conds.get("Ready") == "True"
    node_itype_map[name] = itype
    if itype.startswith("n4d-"):
        n4d_count += 1
        if ready:
            n4d_ready += 1
    node_parts.append(f"{name}[{itype},ready={ready},unsched={unsched}]")

pvc1_bound_hd = 0
pvc_parts = []
for pvc in pvcs:
    pvc_name = pvc["metadata"]["name"]
    phase = pvc.get("status", {}).get("phase", "Unknown")
    vol_name = pvc.get("spec", {}).get("volumeName", "")
    dtype = "pending"
    if vol_name and vol_name in pvs:
        aff = json.dumps(pvs[vol_name].get("spec", {}).get("nodeAffinity", {}))
        m = re.search(r"disk-type\.gke\.io/(pd-[a-z0-9-]+|hyperdisk-[a-z0-9-]+)", aff)
        dtype = m.group(1) if m else "unknown"
    if pvc_name == "data-storage-inspector-1" and phase == "Bound" and dtype == "hyperdisk-balanced":
        pvc1_bound_hd = 1
    pvc_parts.append(f"{pvc_name}[{phase},{dtype}]")

pod0_ok = 0
pod1_ok = 0
pod_parts = []
for p in pods:
    pname = p["metadata"]["name"]
    phase = p.get("status", {}).get("phase", "Unknown")
    nname = p.get("spec", {}).get("nodeName", "<unscheduled>")
    conds = {c["type"]: c["status"] for c in p.get("status", {}).get("conditions", [])}
    pready = conds.get("Ready") == "True"
    del_ts = p["metadata"].get("deletionTimestamp")
    itype = node_itype_map.get(nname, "unknown")
    if pname == "storage-inspector-0" and phase == "Running" and pready and not del_ts and itype.startswith("n2d-"):
        pod0_ok = 1
    if pname == "storage-inspector-1" and phase == "Running" and pready and not del_ts and itype.startswith("n4d-"):
        pod1_ok = 1
    pod_parts.append(f"{pname}[{phase},ready={pready},node={nname}({itype})]")

print(f"N4D_COUNT={n4d_count}|N4D_READY={n4d_ready}|PVC1_HD={pvc1_bound_hd}|POD0_OK={pod0_ok}|POD1_OK={pod1_ok}|NODES={' '.join(node_parts)}|PVCS={' '.join(pvc_parts)}|PODS={' '.join(pod_parts)}|{ca_info}")
PY
)"

  IFS='|' read -r s_n4d s_n4d_ready s_pvc1 s_pod0 s_pod1 s_nodes s_pvcs s_pods s_ca <<<"${STATE_SUMMARY}"
  N4D_COUNT="${s_n4d#N4D_COUNT=}"
  N4D_READY="${s_n4d_ready#N4D_READY=}"
  PVC1_HD="${s_pvc1#PVC1_HD=}"
  POD0_OK="${s_pod0#POD0_OK=}"
  POD1_OK="${s_pod1#POD1_OK=}"

  log "[+${ELAPSED}s] ${s_ca} | ${s_nodes} | ${s_pvcs} | ${s_pods}"

  if [[ -z "${T_N4D_REGISTERED}" && "${N4D_COUNT}" -ge 1 ]]; then
    T_N4D_REGISTERED="${ELAPSED}"
    pass "Gen 4 (n4d Spot) node registered at +${T_N4D_REGISTERED}s."
  fi

  if [[ -z "${T_N4D_READY}" && "${N4D_READY}" -ge 1 ]]; then
    T_N4D_READY="${ELAPSED}"
    pass "Gen 4 (n4d Spot) node reached Ready at +${T_N4D_READY}s."
  fi

  if [[ -z "${T_PVC1_BOUND}" && "${PVC1_HD}" -eq 1 ]]; then
    T_PVC1_BOUND="${ELAPSED}"
    pass "PVC/data-storage-inspector-1 bound to dynamically provisioned hyperdisk-balanced PV at +${T_PVC1_BOUND}s!"
  fi

  if [[ "${POD0_OK}" -eq 1 && "${POD1_OK}" -eq 1 && "${PVC1_HD}" -eq 1 ]]; then
    T_POD1_READY="${ELAPSED}"
    pass "storage-inspector-1 is 1/1 Ready on Gen 4 n4d (hyperdisk-balanced) while storage-inspector-0 remains on Gen 3 n2d (pd-balanced) at +${T_POD1_READY}s!"
    break
  fi

  sleep 10
done

log "Step 8: Verifying Gen 4 n4d node labels and PVC/data-storage-inspector-1 PV Disk-Topology Pinning (disk-type.gke.io/hyperdisk-balanced)..."
POD1_NODE="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod storage-inspector-1 -o jsonpath='{.spec.nodeName}')"
NODE1_JSON="$(kubectl --context="${KUBE_CONTEXT}" get node "${POD1_NODE}" -o json)"
PVC1_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pvc data-storage-inspector-1 -o json)"
PV1_NAME="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pvc data-storage-inspector-1 -o jsonpath='{.spec.volumeName}')"
PV1_JSON="$(kubectl --context="${KUBE_CONTEXT}" get pv "${PV1_NAME}" -o json)"

python3 - "${NODE1_JSON}" "${PVC1_JSON}" "${PV1_JSON}" <<'PY'
import json
import re
import sys

node = json.loads(sys.argv[1])
pvc = json.loads(sys.argv[2])
pv = json.loads(sys.argv[3])

n_name = node["metadata"]["name"]
labels = node["metadata"].get("labels", {})
cc_label = labels.get("cloud.google.com/compute-class")
itype = labels.get("node.kubernetes.io/instance-type", "")
spot = labels.get("cloud.google.com/gke-spot") or labels.get("cloud.google.com/gke-provisioning")
print(f"  Verified Gen 4 node {n_name}: compute-class={cc_label}, instance-type={itype}, spot={spot}")
assert cc_label == "obtainable-stateful", f"Expected compute-class=obtainable-stateful, got {cc_label}"
assert itype.startswith("n4d-"), f"Expected Priority #1 Gen 4 n4d-* machine type, got {itype} on {n_name}"
assert spot in ("true", "spot"), f"Expected Spot provisioning on {n_name}, got {spot}"

assert pvc.get("status", {}).get("phase") == "Bound", f"Expected PVC data-storage-inspector-1 Bound, got {pvc.get('status', {}).get('phase')}"
assert pvc.get("spec", {}).get("storageClassName") == "dynamic-rwo", f"Expected storageClassName=dynamic-rwo, got {pvc.get('spec', {}).get('storageClassName')}"

node_aff = json.dumps(pv.get("spec", {}).get("nodeAffinity", {}))
m = re.search(r"disk-type\.gke\.io/(pd-[a-z0-9-]+|hyperdisk-[a-z0-9-]+)", node_aff)
disk_type = pv.get("spec", {}).get("csi", {}).get("volumeAttributes", {}).get("type") or (m.group(1) if m else None)
print(f"  Verified PV {pv['metadata']['name']}: resolved disk_type={disk_type} (from PV nodeAffinity / volumeAttributes)")
assert disk_type == "hyperdisk-balanced", f"Expected resolved disk_type == 'hyperdisk-balanced' on Gen 4 n4d node, got {disk_type}"
assert "disk-type.gke.io/hyperdisk-balanced" in node_aff, f"Expected PV Disk-Topology Pinning (disk-type.gke.io/hyperdisk-balanced) in PV nodeAffinity, got {node_aff}"
PY
pass "Gen 4 n4d node and PVC/data-storage-inspector-1 (hyperdisk-balanced with disk-type.gke.io/hyperdisk-balanced nodeAffinity) verified."

log "Step 9: Verifying PV Disk-Topology Pinning kept storage-inspector-0 unevicted on Gen 3 n2d (pd-balanced) while storage-inspector-1 runs on Gen 4 n4d (hyperdisk-balanced)..."
POST_POD0_NODE="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod storage-inspector-0 -o jsonpath='{.spec.nodeName}')"
POST_POD0_UID="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod storage-inspector-0 -o jsonpath='{.metadata.uid}')"
POST_PV0_NAME="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pvc data-storage-inspector-0 -o jsonpath='{.spec.volumeName}')"
[[ "${STAGE1_POD0_NODE}" == "${POST_POD0_NODE}" ]] || fail "storage-inspector-0 moved nodes (${STAGE1_POD0_NODE} -> ${POST_POD0_NODE}); PV Disk-Topology Pinning should keep it on its Gen 3 n2d node!"
[[ "${STAGE1_POD0_UID}" == "${POST_POD0_UID}" ]] || fail "storage-inspector-0 was recreated (${STAGE1_POD0_UID} -> ${POST_POD0_UID}); expected zero disruption to existing pd-balanced replica!"
[[ "${STAGE1_PV0_NAME}" == "${POST_PV0_NAME}" ]] || fail "storage-inspector-0 PV changed (${STAGE1_PV0_NAME} -> ${POST_PV0_NAME})!"

verify_pod_storage_report "${KUBE_CONTEXT}" "${NAMESPACE}" "storage-inspector-0" "Gen3" "n2d-" "spot" "data-storage-inspector-0" "pd-balanced"
verify_pod_storage_report "${KUBE_CONTEXT}" "${NAMESPACE}" "storage-inspector-1" "Gen4" "n4d-" "spot" "data-storage-inspector-1" "hyperdisk-balanced"

HISTORY1_LOG="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" exec storage-inspector-1 -- cat /data/replica-history.log)"
echo "--- storage-inspector-1 /data/replica-history.log ---"
echo "${HISTORY1_LOG}"
grep -q "pod=storage-inspector-1" <<<"${HISTORY1_LOG}" || fail "storage-inspector-1 /data/replica-history.log missing pod=storage-inspector-1"
grep -q "DISK_TYPE=hyperdisk-balanced" <<<"${HISTORY1_LOG}" || fail "storage-inspector-1 /data/replica-history.log missing DISK_TYPE=hyperdisk-balanced"
pass "Both replicas verified: storage-inspector-0 on Gen 3 n2d (pd-balanced) and storage-inspector-1 on Gen 4 n4d (hyperdisk-balanced)."

log "Step 10: Capturing 'make status-stateful' in Stage 2 (cross-generation Gen 3 n2d + Gen 4 n4d state)..."
STAGE2_STATUS="$(make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" status-stateful)"
echo "${STAGE2_STATUS}"
STAGE2_PLAIN="$(printf "%s" "${STAGE2_STATUS}" | sed 's/\x1b\[[0-9;]*m//g')"
python3 - "${STAGE2_PLAIN}" <<'PY'
import sys

text = sys.argv[1]
for idx, line in enumerate(text.splitlines(), start=1):
    assert len(line) <= 134, f"Line {idx} exceeds 134 chars ({len(line)} chars): {line}"

for token in (
    "ComputeClass/obtainable-stateful",
    "StorageClass/dynamic-rwo",
    "n2d-",
    "n4d-",
    "Gen3",
    "Gen4",
    "data-storage-inspector-0",
    "data-storage-inspector-1",
    "pd-balanced",
    "hyperdisk-balanced",
    "disk-type.gke.io/pd-balanced",
    "disk-type.gke.io/hyperdisk-balanced",
    "storage-inspector-0",
    "storage-inspector-1",
):
    assert token in text, f"Stage 2 status-stateful output missing expected token: {token}"
PY
pass "Stage 2 'make status-stateful' output and line widths (<= 134 chars) verified."

log "Summary of Live Cross-Generation Stateful Obtainability (Gen 3 n2d pd-balanced + Gen 4 n4d hyperdisk-balanced):"
log "  Replica 0 (Gen 3 n2d Spot, pd-balanced):        ${STAGE1_POD0_NODE} (PV=${STAGE1_PV0_NAME})"
log "  Replica 1 (Gen 4 n4d Spot, hyperdisk-balanced): ${POD1_NODE} (PV=${PV1_NAME})"
log "  Gen 4 n4d Node Registered:                      +${T_N4D_REGISTERED}s after 'make unlock-gen4'"
log "  Gen 4 n4d Node Ready:                           +${T_N4D_READY}s after 'make unlock-gen4'"
log "  PVC/data-storage-inspector-1 Bound (Hyperdisk): +${T_PVC1_BOUND}s after 'make unlock-gen4'"
log "  storage-inspector-1 Ready on Gen 4 n4d:         +${T_POD1_READY}s after 'make unlock-gen4'"
pass "End-to-end Cross-Generation Stateful Obtainability & Dynamic Block Storage Selection verification succeeded!"
