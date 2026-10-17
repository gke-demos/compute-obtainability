#!/usr/bin/env bash

BANNED_TERM="fluid"" compute"

log() {
  local prefix="${LOG_PREFIX:-obtainability}"
  if [[ "${LOG_TIMESTAMP:-false}" == "true" ]]; then
    printf "\033[1;34m[%s %s]\033[0m %s\n" "${prefix}" "$(date -u +%H:%M:%S)" "$*"
  else
    printf "\033[1;34m[%s]\033[0m %s\n" "${prefix}" "$*"
  fi
}

pass() {
  printf "\033[1;32m[PASS]\033[0m %s\n" "$*"
}

fail() {
  printf "\033[1;31m[FAIL]\033[0m %s\n" "$*" >&2
  exit 1
}

check_no_banned_terms() {
  local matches
  matches="$(grep -ri --exclude-dir=.git "${BANNED_TERM}" "$@" 2>/dev/null || true)"
  if [[ -n "${matches}" ]]; then
    echo "${matches}" >&2
    fail "Found banned internal terminology in: $*"
  fi
}

assert_computeclass_schema() {
  local cc_path="$1"
  local stage="$2"
  python3 - "${cc_path}" "${stage}" <<'PY'
import sys
import yaml

cc_path, stage = sys.argv[1], sys.argv[2]

with open(cc_path, "r", encoding="utf-8") as f:
    cc_docs = [d for d in yaml.safe_load_all(f) if d]

assert len(cc_docs) == 1, f"Expected 1 document in {cc_path}, got {len(cc_docs)}"
cc = cc_docs[0]
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
if stage == "stage1":
    assert (
        priorities[0].get("reservations", {}).get("affinity") == "AnyThenFail"
    ), f"Priority #1 reservations.affinity must be AnyThenFail, got {priorities[0]}"
elif stage == "stage2":
    assert priorities[0].get("spot") is True, f"Priority #1 spot must be True in Stage 2, got {priorities[0]}"
    assert "reservations" not in priorities[0], f"Priority #1 in Stage 2 must not require reservations, got {priorities[0]}"
else:
    raise AssertionError(f"Unknown stage: {stage}")

assert priorities[1].get("machineFamily") == "n4d", f"Priority #2 machineFamily must be n4d, got {priorities[1]}"
assert priorities[1].get("spot") is True, f"Priority #2 spot must be True, got {priorities[1]}"
assert priorities[2].get("machineFamily") == "n4", f"Priority #3 machineFamily must be n4, got {priorities[2]}"
assert priorities[2].get("spot") is False, f"Priority #3 spot must be False, got {priorities[2]}"
PY
}

verify_pods_silicon_report() {
  local kube_context="$1"
  local namespace="$2"
  local expected_arch="$3"
  local expected_mt_prefix="$4"
  local expected_prov="$5"

  local pods pod_count=0
  pods="$(kubectl --context="${kube_context}" -n "${namespace}" get pods -l app=silicon-inspector --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')"
  for pod in ${pods}; do
    pod_count=$((pod_count + 1))
    local report=""
    for _ in {1..15}; do
      if report="$(kubectl --context="${kube_context}" -n "${namespace}" exec "${pod}" -- cat /tmp/silicon-report 2>/dev/null)" && [[ -n "${report}" ]]; then
        break
      fi
      sleep 2
    done
    [[ -n "${report}" ]] || fail "Pod ${pod} did not write /tmp/silicon-report"
    echo "--- ${pod} /tmp/silicon-report ---"
    echo "${report}"
    grep -q "^ARCH=${expected_arch}$" <<<"${report}" || fail "Pod ${pod} report missing ARCH=${expected_arch}"
    grep -q "^MACHINE_TYPE=${expected_mt_prefix}" <<<"${report}" || fail "Pod ${pod} report missing MACHINE_TYPE=${expected_mt_prefix}*"
    grep -q "^PROVISIONING=${expected_prov}$" <<<"${report}" || fail "Pod ${pod} report missing PROVISIONING=${expected_prov}"

    local logs
    logs="$(kubectl --context="${kube_context}" -n "${namespace}" logs "${pod}" --tail=5)"
    echo "--- ${pod} stdout logs ---"
    echo "${logs}"
    grep -q "ARCH=${expected_arch}" <<<"${logs}" || fail "Pod ${pod} stdout logs missing ARCH=${expected_arch}"
    grep -q "MACHINE_TYPE=${expected_mt_prefix}" <<<"${logs}" || fail "Pod ${pod} stdout logs missing MACHINE_TYPE=${expected_mt_prefix}*"
    grep -q "PROVISIONING=${expected_prov}" <<<"${logs}" || fail "Pod ${pod} stdout logs missing PROVISIONING=${expected_prov}"
  done

  [[ "${pod_count}" -eq 2 ]] || fail "Expected 2 Running silicon-inspector Pods on ${expected_arch}, found ${pod_count}"
}

assert_stateful_computeclass_schema() {
  local cc_path="$1"
  local stage="$2"
  python3 - "${cc_path}" "${stage}" <<'PY'
import sys
import yaml

cc_path, stage = sys.argv[1], sys.argv[2]

with open(cc_path, "r", encoding="utf-8") as f:
    cc_docs = [d for d in yaml.safe_load_all(f) if d]

assert len(cc_docs) == 1, f"Expected 1 document in {cc_path}, got {len(cc_docs)}"
cc = cc_docs[0]
assert cc.get("apiVersion") == "cloud.google.com/v1", f"Unexpected apiVersion: {cc.get('apiVersion')}"
assert cc.get("kind") == "ComputeClass", f"Unexpected kind: {cc.get('kind')}"
assert cc.get("metadata", {}).get("name") == "obtainable-stateful", "ComputeClass name must be obtainable-stateful"

spec = cc.get("spec", {})
assert spec.get("nodePoolAutoCreation", {}).get("enabled") is True, "nodePoolAutoCreation.enabled must be true"
assert (
    spec.get("activeMigration", {}).get("optimizeRulePriority") is True
), "activeMigration.optimizeRulePriority must be true"
assert spec.get("whenUnsatisfiable") == "DoNotScaleUp", "whenUnsatisfiable must be DoNotScaleUp"

priorities = spec.get("priorities", [])
assert len(priorities) >= 3, f"Expected at least 3 priority rules, got {len(priorities)}"
assert priorities[0].get("machineFamily") == "n4d", f"Priority #1 machineFamily must be n4d, got {priorities[0]}"
if stage == "stage1":
    assert (
        priorities[0].get("reservations", {}).get("affinity") == "AnyThenFail"
    ), f"Priority #1 reservations.affinity must be AnyThenFail, got {priorities[0]}"
elif stage == "stage2":
    assert priorities[0].get("spot") is True, f"Priority #1 spot must be True in Stage 2, got {priorities[0]}"
    assert "reservations" not in priorities[0], f"Priority #1 in Stage 2 must not require reservations, got {priorities[0]}"
else:
    raise AssertionError(f"Unknown stage: {stage}")

assert priorities[1].get("machineFamily") == "n2d", f"Priority #2 machineFamily must be n2d, got {priorities[1]}"
assert priorities[1].get("spot") is True, f"Priority #2 spot must be True, got {priorities[1]}"
assert priorities[2].get("machineFamily") == "n2", f"Priority #3 machineFamily must be n2, got {priorities[2]}"
assert priorities[2].get("spot") is False, f"Priority #3 spot must be False, got {priorities[2]}"
PY
}

verify_pod_storage_report() {
  local kube_context="$1"
  local namespace="$2"
  local pod="$3"
  local expected_vm_gen="$4"
  local expected_mt_prefix="$5"
  local expected_prov="$6"
  local expected_pvc="$7"
  local expected_disk_type="$8"

  local report=""
  for _ in {1..18}; do
    if report="$(kubectl --context="${kube_context}" -n "${namespace}" exec "${pod}" -- cat /tmp/storage-report 2>/dev/null)" && [[ -n "${report}" ]]; then
      if grep -q "^DISK_TYPE=${expected_disk_type}$" <<<"${report}"; then
        break
      fi
    fi
    sleep 2
  done
  [[ -n "${report}" ]] || fail "Pod ${pod} did not write /tmp/storage-report"
  echo "--- ${pod} /tmp/storage-report ---"
  echo "${report}"
  grep -q "^POD_NAME=${pod}$" <<<"${report}" || fail "Pod ${pod} report missing POD_NAME=${pod}"
  grep -q "^NODE_NAME=gke-" <<<"${report}" || fail "Pod ${pod} report missing NODE_NAME=gke-*"
  grep -q "^VM_GEN=${expected_vm_gen}$" <<<"${report}" || fail "Pod ${pod} report missing VM_GEN=${expected_vm_gen}"
  grep -q "^MACHINE_TYPE=${expected_mt_prefix}" <<<"${report}" || fail "Pod ${pod} report missing MACHINE_TYPE=${expected_mt_prefix}*"
  grep -q "^PROVISIONING=${expected_prov}$" <<<"${report}" || fail "Pod ${pod} report missing PROVISIONING=${expected_prov}"
  grep -q "^PVC_NAME=${expected_pvc}$" <<<"${report}" || fail "Pod ${pod} report missing PVC_NAME=${expected_pvc}"
  grep -q "^PV_NAME=pvc-" <<<"${report}" || fail "Pod ${pod} report missing PV_NAME=pvc-*"
  grep -q "^DISK_TYPE=${expected_disk_type}$" <<<"${report}" || fail "Pod ${pod} report missing DISK_TYPE=${expected_disk_type}"
  grep -q "^CPU_MODEL=." <<<"${report}" || fail "Pod ${pod} report missing CPU_MODEL"

  local logs=""
  for _ in {1..6}; do
    logs="$(kubectl --context="${kube_context}" -n "${namespace}" logs "${pod}" --tail=5)"
    if grep -q "DISK_TYPE=${expected_disk_type}" <<<"${logs}"; then
      break
    fi
    sleep 2
  done
  echo "--- ${pod} stdout logs ---"
  echo "${logs}"
  grep -q "pod=${pod}" <<<"${logs}" || fail "Pod ${pod} stdout logs missing pod=${pod}"
  grep -q "VM_GEN=${expected_vm_gen}" <<<"${logs}" || fail "Pod ${pod} stdout logs missing VM_GEN=${expected_vm_gen}"
  grep -q "MACHINE=${expected_mt_prefix}" <<<"${logs}" || fail "Pod ${pod} stdout logs missing MACHINE=${expected_mt_prefix}*"
  grep -q "PROV=${expected_prov}" <<<"${logs}" || fail "Pod ${pod} stdout logs missing PROV=${expected_prov}"
  grep -q "PVC=${expected_pvc}" <<<"${logs}" || fail "Pod ${pod} stdout logs missing PVC=${expected_pvc}"
  grep -q "DISK_TYPE=${expected_disk_type}" <<<"${logs}" || fail "Pod ${pod} stdout logs missing DISK_TYPE=${expected_disk_type}"
}
