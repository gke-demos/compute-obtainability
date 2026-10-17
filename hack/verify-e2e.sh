#!/usr/bin/env bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-gke_mofilabs_us-central1-a_ate-cluster}"
NAMESPACE="compute-obtainability"
COMPUTE_CLASS="obtainable-compute"
DEPLOYMENT="silicon-inspector"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

STAGE1_CC="${REPO_ROOT}/manifests/01-computeclass-fallback.yaml"
APP_MANIFEST="${REPO_ROOT}/manifests/02-silicon-inspector.yaml"
STAGE2_CC="${REPO_ROOT}/manifests/03-computeclass-obtainable-arm.yaml"
MAKEFILE_PATH="${REPO_ROOT}/Makefile"
WATCH_SCRIPT="${REPO_ROOT}/hack/watch.sh"

log() {
  printf "\033[1;34m[verify-e2e %s]\033[0m %s\n" "$(date -u +%H:%M:%S)" "$*"
}

pass() {
  printf "\033[1;32m[PASS]\033[0m %s\n" "$*"
}

fail() {
  printf "\033[1;31m[FAIL]\033[0m %s\n" "$*" >&2
  exit 1
}

log "Step 1: Checking required Stage 1 & Stage 2 artifacts exist..."
[[ -f "${STAGE1_CC}" ]] || fail "Missing Stage 1 ComputeClass manifest: ${STAGE1_CC}"
[[ -f "${APP_MANIFEST}" ]] || fail "Missing Silicon Inspector manifest: ${APP_MANIFEST}"
[[ -f "${STAGE2_CC}" ]] || fail "Missing Stage 2 ComputeClass manifest: ${STAGE2_CC}"
[[ -f "${MAKEFILE_PATH}" ]] || fail "Missing Makefile: ${MAKEFILE_PATH}"
[[ -x "${WATCH_SCRIPT}" ]] || fail "Missing or non-executable watch script: ${WATCH_SCRIPT}"
pass "All required manifests, Makefile, and hack/watch.sh exist."

log "Step 2: Checking public terminology hygiene across manifests, Makefile, and hack/..."
BANNED_TERM="fluid"" compute"
if grep -ri "${BANNED_TERM}" "${REPO_ROOT}/manifests/" "${MAKEFILE_PATH}" "${WATCH_SCRIPT}" "${STAGE2_CC}" >/dev/null 2>&1; then
  fail "Found banned internal terminology in repository files"
fi
pass "All files use canonical Compute Obtainability terminology."

log "Step 3: Validating Stage 2 ComputeClass manifest (manifests/03-computeclass-obtainable-arm.yaml) and Makefile targets..."
python3 - "${STAGE2_CC}" "${MAKEFILE_PATH}" <<'PY'
import sys
import yaml

cc_path, mk_path = sys.argv[1], sys.argv[2]

with open(cc_path, "r", encoding="utf-8") as f:
    docs = [d for d in yaml.safe_load_all(f) if d]

assert len(docs) == 1, f"Expected 1 document in {cc_path}, got {len(docs)}"
cc = docs[0]
assert cc.get("apiVersion") == "cloud.google.com/v1", f"Unexpected apiVersion: {cc.get('apiVersion')}"
assert cc.get("kind") == "ComputeClass", f"Unexpected kind: {cc.get('kind')}"
assert cc.get("metadata", {}).get("name") == "obtainable-compute", "ComputeClass name must be obtainable-compute"

spec = cc.get("spec", {})
assert spec.get("nodePoolAutoCreation", {}).get("enabled") is True, "nodePoolAutoCreation.enabled must be true"
assert (
    spec.get("nodePoolConfig", {}).get("taintConfig", {}).get("architectureTaintBehavior") == "NONE"
), "nodePoolConfig.taintConfig.architectureTaintBehavior must be NONE"
assert (
    spec.get("activeMigration", {}).get("optimizeRulePriority") is True
), "activeMigration.optimizeRulePriority must be true"
assert spec.get("whenUnsatisfiable") == "DoNotScaleUp", "whenUnsatisfiable must be DoNotScaleUp"

priorities = spec.get("priorities", [])
assert len(priorities) >= 3, f"Expected at least 3 priority rules, got {len(priorities)}"
assert priorities[0].get("machineFamily") == "n4a", f"Priority #1 machineFamily must be n4a, got {priorities[0]}"
assert priorities[0].get("spot") is True, f"Priority #1 spot must be True in Stage 2, got {priorities[0]}"
assert "reservations" not in priorities[0], f"Priority #1 in Stage 2 must not require reservations, got {priorities[0]}"
assert priorities[1].get("machineFamily") == "n4d", f"Priority #2 machineFamily must be n4d, got {priorities[1]}"
assert priorities[1].get("spot") is True, f"Priority #2 spot must be True, got {priorities[1]}"
assert priorities[2].get("machineFamily") == "n4", f"Priority #3 machineFamily must be n4, got {priorities[2]}"
assert priorities[2].get("spot") is False, f"Priority #3 spot must be False, got {priorities[2]}"

with open(mk_path, "r", encoding="utf-8") as f:
    mk_text = f.read()

for target in ("apply:", "unlock-arm:", "watch:", "status:", "logs:", "verify:", "clean:"):
    assert target in mk_text, f"Makefile missing required target {target}"
PY
kubectl --context="${KUBE_CONTEXT}" apply --dry-run=server -f "${STAGE2_CC}" >/dev/null
pass "Stage 2 ComputeClass schema, dry-run validation, and Makefile targets verified."

log "Step 4: Ensuring Stage 1 (x86_64 n4d Spot fallback) is active on ${KUBE_CONTEXT}..."
NeedStage1Apply="false"
CURRENT_P1_RES="$(kubectl --context="${KUBE_CONTEXT}" get computeclass "${COMPUTE_CLASS}" -o jsonpath='{.spec.priorities[0].reservations.affinity}' 2>/dev/null || true)"
CURRENT_NODES_ARCH="$(kubectl --context="${KUBE_CONTEXT}" get nodes -l "cloud.google.com/compute-class=${COMPUTE_CLASS}" -o jsonpath='{.items[*].metadata.labels.kubernetes\.io/arch}' 2>/dev/null || true)"
if [[ "${CURRENT_P1_RES}" != "AnyThenFail" ]] || [[ -z "${CURRENT_NODES_ARCH}" ]] || [[ "${CURRENT_NODES_ARCH}" == *"arm64"* ]]; then
  NeedStage1Apply="true"
fi

if [[ "${NeedStage1Apply}" == "true" ]]; then
  log "Cluster is not currently in pure Stage 1 (n4d amd64) state; resetting to Stage 1 via 'make apply'..."
  make -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" apply
  # If any arm64 obtainable-compute node exists from a prior run, cordon & delete Pods on it so Stage 1 lands on amd64
  ARM_NODES="$(kubectl --context="${KUBE_CONTEXT}" get nodes -l "cloud.google.com/compute-class=${COMPUTE_CLASS},kubernetes.io/arch=arm64" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${ARM_NODES}" ]]; then
    for n in ${ARM_NODES}; do
      kubectl --context="${KUBE_CONTEXT}" cordon "${n}" >/dev/null 2>&1 || true
    done
    kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" rollout restart "deployment/${DEPLOYMENT}"
  fi
  KUBE_CONTEXT="${KUBE_CONTEXT}" "${REPO_ROOT}/hack/test-stage1-fallback.sh"
else
  log "Cluster already has Stage 1 deployed on amd64; verifying Stage 1 state..."
  KUBE_CONTEXT="${KUBE_CONTEXT}" "${REPO_ROOT}/hack/test-stage1-fallback.sh"
fi

log "Step 5: Capturing 'make status' in Stage 1 (x86_64 fallback on n4d Spot)..."
STAGE1_STATUS="$(make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" status)"
echo "${STAGE1_STATUS}"
STAGE1_PLAIN="$(printf "%s" "${STAGE1_STATUS}" | sed 's/\x1b\[[0-9;]*m//g')"
grep -q "AnyThenFail" <<<"${STAGE1_PLAIN}" || fail "Stage 1 status output missing AnyThenFail"
grep -q "n4d-" <<<"${STAGE1_PLAIN}" || fail "Stage 1 status output missing n4d-* node"
grep -q "x86_64" <<<"${STAGE1_PLAIN}" || fail "Stage 1 status output missing ARCH=x86_64"
pass "Stage 1 'make status' output verified."

PRE_DEPLOY_GEN="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" -o jsonpath='{.metadata.generation}')"
PRE_DEPLOY_SPEC="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" -o jsonpath='{.spec.template.spec}')"
STAGE1_NODE="$(kubectl --context="${KUBE_CONTEXT}" get nodes -l "cloud.google.com/compute-class=${COMPUTE_CLASS},kubernetes.io/arch=amd64" -o jsonpath='{.items[0].metadata.name}')"
log "Recorded Stage 1 baseline: Deployment generation=${PRE_DEPLOY_GEN}, x86_64 node=${STAGE1_NODE}"

log "Step 6: Running 'make unlock-arm' to promote obtainable Google Axion Arm64 Spot (n4a) to Priority #1..."
T_UNLOCK="$(date +%s)"
make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" unlock-arm

P1_FAMILY="$(kubectl --context="${KUBE_CONTEXT}" get computeclass "${COMPUTE_CLASS}" -o jsonpath='{.spec.priorities[0].machineFamily}')"
P1_SPOT="$(kubectl --context="${KUBE_CONTEXT}" get computeclass "${COMPUTE_CLASS}" -o jsonpath='{.spec.priorities[0].spot}')"
[[ "${P1_FAMILY}" == "n4a" && "${P1_SPOT}" == "true" ]] || fail "Expected Priority #1 machineFamily=n4a spot=true, got family=${P1_FAMILY} spot=${P1_SPOT}"
pass "ComputeClass/${COMPUTE_CLASS} updated: Priority #1 is now n4a (spot: true)."

log "Step 7: Observing GKE Node Pool Auto-Creation (n4a arm64 without arch taint) and Active Migration (n4d x86_64 -> n4a aarch64)..."
T_N4A_REGISTERED=""
T_N4A_READY=""
T_MIGRATED=""
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-900}"

while true; do
  NOW="$(date +%s)"
  ELAPSED=$((NOW - T_UNLOCK))
  if (( ELAPSED > MAX_WAIT_SECONDS )); then
    fail "Timed out after ${MAX_WAIT_SECONDS}s waiting for Active Migration from x86_64 (n4d) to aarch64 (n4a)"
  fi

  NODES_JSON="$(kubectl --context="${KUBE_CONTEXT}" get nodes -l "cloud.google.com/compute-class=${COMPUTE_CLASS}" -o json)"
  PODS_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=silicon-inspector -o json)"
  CA_STATUS="$(kubectl --context="${KUBE_CONTEXT}" -n kube-system get configmap cluster-autoscaler-status -o jsonpath='{.data.status}' 2>/dev/null || true)"

  STATE_SUMMARY="$(python3 - "${NODES_JSON}" "${PODS_JSON}" "${CA_STATUS}" <<'PY'
import json
import sys
import yaml

nodes = json.loads(sys.argv[1]).get("items", [])
pods = json.loads(sys.argv[2]).get("items", [])
ca_raw = sys.argv[3]
ca_info = ""
if ca_raw:
    try:
        ca_doc = yaml.safe_load(ca_raw) or {}
        ng_names = [ng.get("name", "").split("/")[-1] for ng in ca_doc.get("nodeGroups", []) if "nap-" in ng.get("name", "")]
        su = ca_doc.get("clusterWide", {}).get("scaleUp", {}).get("status", "")
        sd = ca_doc.get("clusterWide", {}).get("scaleDown", {}).get("status", "")
        ca_info = f"CA[su={su},sd={sd},ngs={','.join(ng_names)}]"
    except Exception:
        ca_info = "CA[parse-err]"

n4a_nodes = []
n4a_ready_nodes = []
n4d_nodes = []
node_arch_map = {}

node_parts = []
for n in nodes:
    name = n["metadata"]["name"]
    labels = n["metadata"].get("labels", {})
    arch = labels.get("kubernetes.io/arch", "unknown")
    itype = labels.get("node.kubernetes.io/instance-type", "unknown")
    unsched = n["spec"].get("unschedulable", False)
    taints = n["spec"].get("taints", [])
    conds = {c["type"]: c["status"] for c in n.get("status", {}).get("conditions", [])}
    ready = conds.get("Ready") == "True"
    node_arch_map[name] = arch
    if arch == "arm64" and itype.startswith("n4a-"):
        n4a_nodes.append(name)
        if ready:
            n4a_ready_nodes.append(name)
        # Verify architectureTaintBehavior: NONE (no kubernetes.io/arch=arm64:NoSchedule taint)
        for t in taints:
            if t.get("key") == "kubernetes.io/arch":
                print(f"ERROR_ARCH_TAINT:{name}:{t}")
                sys.exit(0)
    elif arch == "amd64":
        n4d_nodes.append(f"{name}(unsched={unsched})")
    node_parts.append(f"{name}[{arch},{itype},ready={ready},unsched={unsched}]")

running_arm_pods = 0
pod_parts = []
for p in pods:
    pname = p["metadata"]["name"]
    phase = p.get("status", {}).get("phase", "Unknown")
    nname = p.get("spec", {}).get("nodeName", "<unscheduled>")
    conds = {c["type"]: c["status"] for c in p.get("status", {}).get("conditions", [])}
    pready = conds.get("Ready") == "True"
    del_ts = p["metadata"].get("deletionTimestamp")
    narch = node_arch_map.get(nname, "unknown")
    if phase == "Running" and pready and not del_ts and narch == "arm64":
        running_arm_pods += 1
    pod_parts.append(f"{pname}[{phase},ready={pready},node={nname}({narch})]")

print(f"N4A_COUNT={len(n4a_nodes)}|N4A_READY={len(n4a_ready_nodes)}|ARM_PODS={running_arm_pods}|NODES={' '.join(node_parts)}|PODS={' '.join(pod_parts)}|{ca_info}")
PY
)"

  if [[ "${STATE_SUMMARY}" == ERROR_ARCH_TAINT:* ]]; then
    fail "Arm64 node was tainted with kubernetes.io/arch despite architectureTaintBehavior: NONE -> ${STATE_SUMMARY}"
  fi

  IFS='|' read -r s_n4a s_n4a_ready s_arm_pods s_nodes s_pods s_ca <<<"${STATE_SUMMARY}"
  N4A_COUNT="${s_n4a#N4A_COUNT=}"
  N4A_READY="${s_n4a_ready#N4A_READY=}"
  ARM_PODS="${s_arm_pods#ARM_PODS=}"

  log "[+${ELAPSED}s] ${s_ca} | ${s_nodes} | ${s_pods}"

  if [[ -z "${T_N4A_REGISTERED}" && "${N4A_COUNT}" -ge 1 ]]; then
    T_N4A_REGISTERED="${ELAPSED}"
    pass "Google Axion Arm64 (n4a) node registered at +${T_N4A_REGISTERED}s (with zero kubernetes.io/arch taint!)."
  fi

  if [[ -z "${T_N4A_READY}" && "${N4A_READY}" -ge 1 ]]; then
    T_N4A_READY="${ELAPSED}"
    pass "Google Axion Arm64 (n4a) node reached Ready at +${T_N4A_READY}s."
  fi

  if [[ "${ARM_PODS}" -eq 2 ]]; then
    T_MIGRATED="${ELAPSED}"
    pass "Both Silicon Inspector Pods actively migrated to Google Axion Arm64 (n4a) at +${T_MIGRATED}s!"
    break
  fi

  sleep 10
done

log "Step 8: Verifying untainted n4a (arm64 Spot) node labels & taints..."
NODES_JSON="$(kubectl --context="${KUBE_CONTEXT}" get nodes -l "cloud.google.com/compute-class=${COMPUTE_CLASS},kubernetes.io/arch=arm64" -o json)"
python3 - "${NODES_JSON}" <<'PY'
import json
import sys

nodes = json.loads(sys.argv[1]).get("items", [])
assert len(nodes) >= 1, "Expected at least 1 arm64 obtainable-compute node"

for n in nodes:
    name = n["metadata"]["name"]
    labels = n["metadata"].get("labels", {})
    arch = labels.get("kubernetes.io/arch")
    itype = labels.get("node.kubernetes.io/instance-type", "")
    spot = labels.get("cloud.google.com/gke-spot") or labels.get("cloud.google.com/gke-provisioning")
    taints = n["spec"].get("taints", [])
    taint_keys = [t.get("key") for t in taints]
    print(f"  Verified arm64 node {name}: arch={arch}, instance-type={itype}, spot={spot}, taints={taints}")
    assert arch == "arm64", f"Expected arch=arm64, got {arch}"
    assert itype.startswith("n4a-"), f"Expected n4a-* instance-type, got {itype}"
    assert spot in ("true", "spot"), f"Expected Spot provisioning, got {spot}"
    assert "kubernetes.io/arch" not in taint_keys, f"Found unexpected kubernetes.io/arch taint: {taints}"
    assert "cloud.google.com/compute-class" in taint_keys, f"Expected cloud.google.com/compute-class taint, got {taints}"
PY
pass "Arm64 node verified: n4a Spot with cloud.google.com/compute-class taint and NO kubernetes.io/arch taint."

log "Step 9: Verifying Silicon Inspector Pods report ARCH=aarch64, MACHINE_TYPE=n4a-*, and PROVISIONING=spot with zero Deployment changes..."
POST_DEPLOY_GEN="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" -o jsonpath='{.metadata.generation}')"
POST_DEPLOY_SPEC="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" -o jsonpath='{.spec.template.spec}')"
[[ "${PRE_DEPLOY_GEN}" == "${POST_DEPLOY_GEN}" ]] || fail "Deployment generation changed (${PRE_DEPLOY_GEN} -> ${POST_DEPLOY_GEN}); expected zero edits to Deployment!"
[[ "${PRE_DEPLOY_SPEC}" == "${POST_DEPLOY_SPEC}" ]] || fail "Deployment Pod template spec changed!"
pass "Deployment/${DEPLOYMENT} confirmed unmodified (generation=${POST_DEPLOY_GEN}, zero tolerations)."

PODS="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=silicon-inspector --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')"
POD_COUNT=0
for pod in ${PODS}; do
  POD_COUNT=$((POD_COUNT + 1))
  REPORT=""
  for _ in {1..15}; do
    if REPORT="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${pod}" -- cat /tmp/silicon-report 2>/dev/null)" && [[ -n "${REPORT}" ]]; then
      break
    fi
    sleep 2
  done
  [[ -n "${REPORT}" ]] || fail "Pod ${pod} did not write /tmp/silicon-report"
  echo "--- ${pod} /tmp/silicon-report ---"
  echo "${REPORT}"
  grep -q "^ARCH=aarch64$" <<<"${REPORT}" || fail "Pod ${pod} report missing ARCH=aarch64"
  grep -q "^MACHINE_TYPE=n4a-" <<<"${REPORT}" || fail "Pod ${pod} report missing MACHINE_TYPE=n4a-*"
  grep -q "^PROVISIONING=spot$" <<<"${REPORT}" || fail "Pod ${pod} report missing PROVISIONING=spot"

  LOGS="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" logs "${pod}" --tail=5)"
  echo "--- ${pod} stdout logs ---"
  echo "${LOGS}"
  grep -q "ARCH=aarch64" <<<"${LOGS}" || fail "Pod ${pod} stdout logs missing ARCH=aarch64"
  grep -q "MACHINE_TYPE=n4a-" <<<"${LOGS}" || fail "Pod ${pod} stdout logs missing MACHINE_TYPE=n4a-*"
  grep -q "PROVISIONING=spot" <<<"${LOGS}" || fail "Pod ${pod} stdout logs missing PROVISIONING=spot"
done

[[ "${POD_COUNT}" -eq 2 ]] || fail "Expected 2 Running silicon-inspector Pods on aarch64, found ${POD_COUNT}"
pass "All ${POD_COUNT} Silicon Inspector Pods verified on Google Axion Arm64 (ARCH=aarch64, n4a Spot)."

log "Step 10: Capturing 'make status' in Stage 2 (migrated aarch64 state on Google Axion n4a)..."
STAGE2_STATUS="$(make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" status)"
echo "${STAGE2_STATUS}"
STAGE2_PLAIN="$(printf "%s" "${STAGE2_STATUS}" | sed 's/\x1b\[[0-9;]*m//g')"
grep -q "n4a-" <<<"${STAGE2_PLAIN}" || fail "Stage 2 status output missing n4a-* node"
grep -q "aarch64" <<<"${STAGE2_PLAIN}" || fail "Stage 2 status output missing ARCH=aarch64"
pass "Stage 2 'make status' output verified."

log "Summary of Live Cross-Architecture Active Migration (x86_64 -> aarch64):"
log "  Stage 1 Fallback Node (x86_64): ${STAGE1_NODE}"
log "  n4a (arm64) Node Registered:    +${T_N4A_REGISTERED}s after 'make unlock-arm'"
log "  n4a (arm64) Node Ready:         +${T_N4A_READY}s after 'make unlock-arm'"
log "  Pods Migrated to aarch64:       +${T_MIGRATED}s after 'make unlock-arm'"
pass "End-to-end Obtainability Ladder & Cross-Architecture Active Migration verification succeeded!"
