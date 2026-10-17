#!/usr/bin/env bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-gke_mofilabs_us-central1-a_ate-cluster}"
NAMESPACE="${NAMESPACE:-obtainability-stateful}"
COMPUTE_CLASS="${COMPUTE_CLASS:-obtainable-stateful}"
STORAGE_CLASS="${STORAGE_CLASS:-dynamic-rwo}"
WATCH_INTERVAL="${WATCH_INTERVAL:-5}"

ONCE="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once|-1)
      ONCE="true"
      shift
      ;;
    --interval|-n)
      WATCH_INTERVAL="${2:-5}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

render_snapshot() {
  local cc_json sc_json nodes_json pvcs_json pvs_json pods_json ca_json
  cc_json="$(kubectl --context="${KUBE_CONTEXT}" get computeclass "${COMPUTE_CLASS}" -o json 2>/dev/null || echo "{}")"
  sc_json="$(kubectl --context="${KUBE_CONTEXT}" get storageclass "${STORAGE_CLASS}" -o json 2>/dev/null || echo "{}")"
  nodes_json="$(kubectl --context="${KUBE_CONTEXT}" get nodes -l "cloud.google.com/compute-class=${COMPUTE_CLASS}" -o json 2>/dev/null || echo '{"items":[]}')"
  pvcs_json="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pvc -o json 2>/dev/null || echo '{"items":[]}')"
  pvs_json="$(kubectl --context="${KUBE_CONTEXT}" get pv -o json 2>/dev/null || echo '{"items":[]}')"
  pods_json="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=storage-inspector -o json 2>/dev/null || echo '{"items":[]}')"
  ca_json="$(kubectl --context="${KUBE_CONTEXT}" -n kube-system get configmap cluster-autoscaler-status -o json 2>/dev/null || echo '{}')"

  # Collect live /tmp/storage-report from Running Pods
  local reports_raw=""
  local pod_names
  pod_names="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=storage-inspector --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  for p in ${pod_names}; do
    local rep
    rep="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${p}" -- cat /tmp/storage-report 2>/dev/null || true)"
    if [[ -n "${rep}" ]]; then
      reports_raw+="__POD_REPORT_START__:${p}"$'\n'"${rep}"$'\n'"__POD_REPORT_END__"$'\n'
    fi
  done

  python3 - "${KUBE_CONTEXT}" "${cc_json}" "${sc_json}" "${nodes_json}" "${pvcs_json}" "${pvs_json}" "${pods_json}" "${reports_raw}" "${ca_json}" <<'PY'
import datetime
import json
import re
import sys
import yaml

ctx = sys.argv[1]
cc = json.loads(sys.argv[2] or "{}")
sc = json.loads(sys.argv[3] or "{}")
nodes = json.loads(sys.argv[4] or '{"items":[]}').get("items", [])
pvcs = json.loads(sys.argv[5] or '{"items":[]}').get("items", [])
pvs_list = json.loads(sys.argv[6] or '{"items":[]}').get("items", [])
pods = json.loads(sys.argv[7] or '{"items":[]}').get("items", [])
reports_raw = sys.argv[8]
ca_cm = json.loads(sys.argv[9] or "{}")

pvs = {pv["metadata"]["name"]: pv for pv in pvs_list if "metadata" in pv}

BOLD = "\033[1m"
DIM = "\033[2m"
CYAN = "\033[1;36m"
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
RED = "\033[1;31m"
RESET = "\033[0m"

reports = {}
current_pod = None
for line in reports_raw.splitlines():
    if line.startswith("__POD_REPORT_START__:"):
        current_pod = line.split(":", 1)[1].strip()
        reports[current_pod] = {}
    elif line == "__POD_REPORT_END__":
        current_pod = None
    elif current_pod and "=" in line:
        k, v = line.strip().split("=", 1)
        reports[current_pod][k.strip()] = v.strip()

def infer_vm_gen(itype: str) -> str:
    if itype.startswith(("n4", "c4", "m4")):
        return "Gen4"
    if itype.startswith(("n2", "c2", "t2", "m2")):
        return "Gen3"
    if itype.startswith(("e2", "n1")):
        return "Gen2"
    return "Unknown"

def extract_pv_disk_and_topo(pv_obj: dict):
    if not pv_obj:
        return ("-", "-")
    aff_str = json.dumps(pv_obj.get("spec", {}).get("nodeAffinity", {}))
    m = re.search(r"(disk-type\.gke\.io/(pd-[a-z0-9-]+|hyperdisk-[a-z0-9-]+))", aff_str)
    topo_key = m.group(1) if m else "-"
    dtype = pv_obj.get("spec", {}).get("csi", {}).get("volumeAttributes", {}).get("type") or (m.group(2) if m else "-")
    topo_disp = f"{topo_key}=true" if topo_key != "-" else "-"
    return (dtype, topo_disp)

now_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
print(f"{BOLD}{CYAN}=== GKE 1.37 Stateful Storage Obtainability Observer ({now_utc}) ==={RESET}")
print(f"{DIM}Cluster Context: {ctx}{RESET}\n")

# Section 1: ComputeClass Obtainability Ladder & StorageClass
print(f"{BOLD}[1] ComputeClass Obtainability Ladder & StorageClass (ComputeClass/obtainable-stateful + StorageClass/dynamic-rwo){RESET}")
if not cc or "spec" not in cc:
    print(f"  {RED}ComputeClass/obtainable-stateful not found{RESET}")
else:
    spec = cc.get("spec", {})
    conds = cc.get("status", {}).get("conditions", [])
    health_status = "Unknown"
    health_msg = ""
    for c in conds:
        if c.get("type") == "Health":
            health_status = c.get("status", "Unknown")
            health_msg = c.get("message", "")
    h_color = GREEN if health_status == "True" else YELLOW
    active_mig = spec.get("activeMigration", {}).get("optimizeRulePriority", False)
    auto_create = spec.get("nodePoolAutoCreation", {}).get("enabled", False)
    consol_delay = spec.get("autoscalingPolicy", {}).get("consolidationDelayMinutes", "-")
    consol_thresh = spec.get("autoscalingPolicy", {}).get("consolidationThreshold", "-")

    ca_health = "Unknown"
    ca_scale_up = "Unknown"
    ca_raw = ca_cm.get("data", {}).get("status", "")
    if ca_raw:
        try:
            ca_doc = yaml.safe_load(ca_raw) or {}
            cw = ca_doc.get("clusterWide", {})
            ca_health = cw.get("health", {}).get("status", "Unknown")
            ca_scale_up = cw.get("scaleUp", {}).get("status", "Unknown")
        except Exception:
            pass

    print(
        f"  ComputeClass: Health={h_color}{health_status}{RESET} ({health_msg}) | "
        f"optimizeRulePriority={GREEN}{active_mig}{RESET} | "
        f"autoCreate={GREEN}{auto_create}{RESET} | "
        f"CA={ca_health}/{ca_scale_up}"
    )

    sc_params = sc.get("parameters", {})
    sc_bind = sc.get("volumeBindingMode", "-")
    sc_type = sc_params.get("type", "-")
    sc_hd = sc_params.get("hyperdisk-type", "-")
    sc_pd = sc_params.get("pd-type", "-")
    sc_topo = sc_params.get("use-allowed-disk-topology", "-")
    print(
        f"  StorageClass/dynamic-rwo: mode={sc_bind} | type={GREEN}{sc_type}{RESET} | "
        f"gen4={GREEN}{sc_hd}{RESET} | gen3={YELLOW}{sc_pd}{RESET} | topoPin={GREEN}{sc_topo}{RESET}"
    )

    family_meta = {
        "n4d": ("Gen4", "AMD EPYC Turin (Hyperdisk-only)"),
        "n4":  ("Gen4", "Intel Emerald Rapids (Hyperdisk)"),
        "n2d": ("Gen3", "AMD EPYC Milan (Persistent Disk)"),
        "n2":  ("Gen3", "Intel Ice Lake (Persistent Disk)"),
    }
    priorities = spec.get("priorities", [])
    for idx, p in enumerate(priorities, start=1):
        fam = p.get("machineFamily", "unknown")
        gen_desc, hw_desc = family_meta.get(fam, ("Gen?", "Unknown"))
        if "reservations" in p:
            aff = p["reservations"].get("affinity", "Unknown")
            mode = f"{YELLOW}reservations.affinity={aff}{RESET} (Fail-Fast)"
        elif p.get("spot") is True:
            mode = f"{GREEN}spot=true{RESET} (Obtainable Spot VM)"
        else:
            mode = "spot=false (On-Demand Fallback)"
        print(f"  Priority #{idx}: machineFamily={BOLD}{fam:<4}{RESET} [{gen_desc} | {hw_desc:<32}] -> {mode}")
print()

# Section 2: Obtainable-Stateful Nodes
print(f"{BOLD}[2] Obtainable-Stateful Nodes (-l cloud.google.com/compute-class=obtainable-stateful){RESET}")
node_itype_map = {}
if not nodes:
    print(f"  {YELLOW}No obtainable-stateful nodes currently provisioned{RESET}\n")
else:
    header = f"  {'NODE':<51} {'STATUS':<8} {'VM-GEN':<6} {'INSTANCE-TYPE':<14} {'SPOT':<4} {'TAINTS'}"
    print(f"{DIM}{header}{RESET}")
    for n in nodes:
        name = n["metadata"]["name"]
        labels = n["metadata"].get("labels", {})
        itype = labels.get("node.kubernetes.io/instance-type", "unknown")
        node_itype_map[name] = itype
        vm_gen = infer_vm_gen(itype)
        spot = labels.get("cloud.google.com/gke-spot") or labels.get("cloud.google.com/gke-provisioning", "false")
        conds = {c["type"]: c["status"] for c in n.get("status", {}).get("conditions", [])}
        status = "Ready" if conds.get("Ready") == "True" else "NotReady"
        if n.get("spec", {}).get("unschedulable"):
            status = "Cordoned" if status == "Ready" else "NotReady"
        taints = n.get("spec", {}).get("taints", [])
        taint_keys = {t.get("key", "") for t in taints}
        short_taints = []
        for t in taints:
            k = t.get("key", "")
            v = t.get("value", "")
            eff = t.get("effect", "")
            if k == "cloud.google.com/compute-class":
                short_taints.append(f"compute-class:{eff}")
            elif k == "ToBeDeletedByClusterAutoscaler":
                short_taints.append("ToBeDeletedByCA")
            elif k == "autoscaling.gke.io/defrag-candidate":
                if "ToBeDeletedByClusterAutoscaler" not in taint_keys:
                    short_taints.append("defrag-candidate")
            elif k in (
                "autoscaling.gke.io/defrag-soft-candidate",
                "DeletionCandidateOfClusterAutoscaler",
                "node.kubernetes.io/unschedulable",
                "node.kubernetes.io/not-ready",
                "node.kubernetes.io/unreachable",
                "node.kubernetes.io/network-unavailable",
                "node.kubernetes.io/disk-pressure",
                "node.kubernetes.io/memory-pressure",
                "node.kubernetes.io/pid-pressure",
                "node.cloudprovider.kubernetes.io/uninitialized",
            ):
                continue
            else:
                short_taints.append(f"{k}={v}:{eff}")
        taint_summary = ", ".join(short_taints) if short_taints else "<none>"
        if len(taint_summary) > 42:
            taint_summary = taint_summary[:39] + "..."
        gen_col = f"{GREEN}{vm_gen:<6}{RESET}" if vm_gen == "Gen4" else f"{YELLOW}{vm_gen:<6}{RESET}"
        print(f"  {name:<51} {status:<8} {gen_col} {itype:<14} {str(spot):<4} {taint_summary}")
    print()

# Section 3: Dynamic Block Volumes (PVCs & PVs)
print(f"{BOLD}[3] Dynamic Block Volumes (PVCs & PVs in namespace obtainability-stateful){RESET}")
pvc_disk_map = {}
if not pvcs:
    print(f"  {YELLOW}No PersistentVolumeClaims found in {ctx}/{RESET}\n")
else:
    header = f"  {'PVC':<24} {'STATUS':<7} {'CLASS':<11} {'VOLUME':<20} {'DISK-TYPE':<18} {'TOPOLOGY-AFFINITY'}"
    print(f"{DIM}{header}{RESET}")
    for pvc in pvcs:
        pvc_name = pvc["metadata"]["name"]
        phase = pvc.get("status", {}).get("phase", "Unknown")
        sc_name = pvc.get("spec", {}).get("storageClassName", "-")
        vol_name = pvc.get("spec", {}).get("volumeName", "<unbound>")
        short_vol = (vol_name[:12] + "..." + vol_name[-5:]) if len(vol_name) > 20 else vol_name
        pv_obj = pvs.get(vol_name)
        dtype, topo_disp = extract_pv_disk_and_topo(pv_obj)
        pvc_disk_map[pvc_name] = dtype
        if dtype.startswith("hyperdisk-"):
            dtype_col = f"{GREEN}{dtype:<18}{RESET}"
        elif dtype.startswith("pd-"):
            dtype_col = f"{YELLOW}{dtype:<18}{RESET}"
        else:
            dtype_col = f"{dtype:<18}"
        print(f"  {pvc_name:<24} {phase:<7} {sc_name:<11} {short_vol:<20} {dtype_col} {topo_disp}")
    print()

# Section 4: Storage Inspector StatefulSet Pods
print(f"{BOLD}[4] Storage Inspector StatefulSet Pods (StatefulSet/storage-inspector in obtainability-stateful){RESET}")
if not pods:
    print(f"  {YELLOW}No storage-inspector Pods found{RESET}")
else:
    header = f"  {'POD':<19} {'STATUS':<7} {'VM-GEN':<6} {'MACHINE-TYPE':<14} {'DISK-TYPE':<18} {'MOUNT':<11} {'NODE'}"
    print(f"{DIM}{header}{RESET}")
    for p in pods:
        pname = p["metadata"]["name"]
        phase = p.get("status", {}).get("phase", "Unknown")
        if p["metadata"].get("deletionTimestamp"):
            phase = "Term"
        nname = p.get("spec", {}).get("nodeName", "<pending>")
        rep = reports.get(pname, {})
        mtype = rep.get("MACHINE_TYPE") or node_itype_map.get(nname, "-")
        vm_gen = rep.get("VM_GEN") or (infer_vm_gen(mtype) if mtype != "-" else "-")
        pvc_name = f"data-{pname}"
        dtype = rep.get("DISK_TYPE") or pvc_disk_map.get(pvc_name, "-")
        mount_str = "/data(10Gi)"
        gen_col = f"{GREEN}{vm_gen:<6}{RESET}" if vm_gen == "Gen4" else (f"{YELLOW}{vm_gen:<6}{RESET}" if vm_gen == "Gen3" else f"{vm_gen:<6}")
        if dtype.startswith("hyperdisk-"):
            dtype_col = f"{GREEN}{dtype:<18}{RESET}"
        elif dtype.startswith("pd-"):
            dtype_col = f"{YELLOW}{dtype:<18}{RESET}"
        else:
            dtype_col = f"{dtype:<18}"
        print(f"  {pname:<19} {phase:<7} {gen_col} {mtype:<14} {dtype_col} {mount_str:<11} {nname}")
PY
}

if [[ "${ONCE}" == "true" ]]; then
  render_snapshot
  exit 0
fi

while true; do
  out="$(render_snapshot)"
  printf '\033[H\033[2J%s' "${out}"
  sleep "${WATCH_INTERVAL}"
done
