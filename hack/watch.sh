#!/usr/bin/env bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-gke_mofilabs_us-central1-a_ate-cluster}"
NAMESPACE="${NAMESPACE:-compute-obtainability}"
COMPUTE_CLASS="${COMPUTE_CLASS:-obtainable-compute}"
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
  local cc_json nodes_json pods_json
  cc_json="$(kubectl --context="${KUBE_CONTEXT}" get computeclass "${COMPUTE_CLASS}" -o json 2>/dev/null || echo "{}")"
  nodes_json="$(kubectl --context="${KUBE_CONTEXT}" get nodes -l "cloud.google.com/compute-class=${COMPUTE_CLASS}" -o json 2>/dev/null || echo '{"items":[]}')"
  pods_json="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=silicon-inspector -o json 2>/dev/null || echo '{"items":[]}')"

  # Collect live /tmp/silicon-report from Running Pods
  local reports_raw=""
  local pod_names
  pod_names="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=silicon-inspector --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  for p in ${pod_names}; do
    local rep
    rep="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${p}" -- cat /tmp/silicon-report 2>/dev/null || true)"
    if [[ -n "${rep}" ]]; then
      reports_raw+="__POD_REPORT_START__:${p}"$'\n'"${rep}"$'\n'"__POD_REPORT_END__"$'\n'
    fi
  done

  python3 - "${KUBE_CONTEXT}" "${cc_json}" "${nodes_json}" "${pods_json}" "${reports_raw}" <<'PY'
import datetime
import json
import sys

ctx = sys.argv[1]
cc = json.loads(sys.argv[2] or "{}")
nodes = json.loads(sys.argv[3] or '{"items":[]}').get("items", [])
pods = json.loads(sys.argv[4] or '{"items":[]}').get("items", [])
reports_raw = sys.argv[5]

BOLD = "\033[1m"
DIM = "\033[2m"
CYAN = "\033[1;36m"
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
MAGENTA = "\033[1;35m"
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

now_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
print(f"{BOLD}{CYAN}=== GKE 1.37 Compute Obtainability Observer ({now_utc}) ==={RESET}")
print(f"{DIM}Cluster Context: {ctx}{RESET}\n")

# Section 1: ComputeClass Obtainability Ladder & Health
print(f"{BOLD}[1] ComputeClass Obtainability Ladder & Health (ComputeClass/obtainable-compute){RESET}")
if not cc or "spec" not in cc:
    print(f"  {RED}ComputeClass/obtainable-compute not found{RESET}\n")
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
    arch_taint = spec.get("nodePoolConfig", {}).get("taintConfig", {}).get("architectureTaintBehavior", "DEFAULT")
    active_mig = spec.get("activeMigration", {}).get("optimizeRulePriority", False)
    auto_create = spec.get("nodePoolAutoCreation", {}).get("enabled", False)
    consol_delay = spec.get("autoscalingPolicy", {}).get("consolidationDelayMinutes", "-")
    consol_thresh = spec.get("autoscalingPolicy", {}).get("consolidationThreshold", "-")

    print(
        f"  Health: {h_color}{health_status}{RESET} ({health_msg}) | "
        f"architectureTaintBehavior: {GREEN}{arch_taint}{RESET} | "
        f"optimizeRulePriority: {GREEN}{active_mig}{RESET} | "
        f"nodePoolAutoCreation: {GREEN}{auto_create}{RESET} | "
        f"consolidation: {consol_delay}m/{consol_thresh}%"
    )

    family_meta = {
        "n4a": ("arm64 / aarch64", "Google Axion (Arm Neoverse-N3)"),
        "c4a": ("arm64 / aarch64", "Google Axion (Arm Neoverse-V2)"),
        "n4d": ("amd64 / x86_64", "AMD EPYC Turin"),
        "n4": ("amd64 / x86_64", "Intel Emerald Rapids"),
    }
    priorities = spec.get("priorities", [])
    for idx, p in enumerate(priorities, start=1):
        fam = p.get("machineFamily", "unknown")
        arch_desc, cpu_desc = family_meta.get(fam, ("unknown", "unknown"))
        if "reservations" in p:
            aff = p["reservations"].get("affinity", "Unknown")
            mode = f"{YELLOW}reservations.affinity={aff}{RESET} (Fail-Fast Reservation Affinity)"
        elif p.get("spot") is True:
            mode = f"{GREEN}spot=true{RESET} (Obtainable Spot VM)"
        else:
            mode = f"spot=false (On-Demand Fallback)"
        print(f"  Priority #{idx}: machineFamily={BOLD}{fam:<4}{RESET} [{arch_desc} - {cpu_desc}] -> {mode}")
    print()

# Section 2: Obtainable-Compute Nodes
print(f"{BOLD}[2] Obtainable-Compute Nodes (-l cloud.google.com/compute-class=obtainable-compute){RESET}")
if not nodes:
    print(f"  {YELLOW}No obtainable-compute nodes currently provisioned{RESET}\n")
else:
    header = f"  {'NODE':<56} {'STATUS':<20} {'ARCH':<8} {'INSTANCE-TYPE':<16} {'SPOT':<6} {'TAINTS'}"
    print(f"{DIM}{header}{RESET}")
    for n in nodes:
        name = n["metadata"]["name"]
        labels = n["metadata"].get("labels", {})
        arch = labels.get("kubernetes.io/arch", "unknown")
        itype = labels.get("node.kubernetes.io/instance-type", "unknown")
        spot = labels.get("cloud.google.com/gke-spot") or labels.get("cloud.google.com/gke-provisioning", "false")
        conds = {c["type"]: c["status"] for c in n.get("status", {}).get("conditions", [])}
        status = "Ready" if conds.get("Ready") == "True" else "NotReady"
        if n.get("spec", {}).get("unschedulable"):
            status += ",SchedulingDisabled"
        taints = n.get("spec", {}).get("taints", [])
        taint_strs = [f"{t.get('key')}={t.get('value', '')}:{t.get('effect')}" for t in taints]
        has_arch_taint = any(t.get("key") == "kubernetes.io/arch" for t in taints)
        taint_summary = ", ".join(taint_strs) if taint_strs else "<none>"
        if arch == "arm64" and not has_arch_taint:
            taint_summary += f" {GREEN}(no arm64 arch taint){RESET}"
        arch_col = f"{GREEN}{arch:<8}{RESET}" if arch == "arm64" else f"{YELLOW}{arch:<8}{RESET}"
        print(f"  {name:<56} {status:<20} {arch_col} {itype:<16} {str(spot):<6} {taint_summary}")
    print()

# Section 3: Silicon Inspector Pods
print(f"{BOLD}[3] Silicon Inspector Pods (Deployment/silicon-inspector in namespace compute-obtainability){RESET}")
if not pods:
    print(f"  {YELLOW}No silicon-inspector Pods found{RESET}")
else:
    header = f"  {'POD':<36} {'STATUS':<14} {'ARCH (uname -m)':<16} {'MACHINE-TYPE':<16} {'PROV':<8} {'NODE':<50} {'CPU-MODEL'}"
    print(f"{DIM}{header}{RESET}")
    for p in pods:
        pname = p["metadata"]["name"]
        phase = p.get("status", {}).get("phase", "Unknown")
        if p["metadata"].get("deletionTimestamp"):
            phase = "Terminating"
        nname = p.get("spec", {}).get("nodeName", "<pending>")
        rep = reports.get(pname, {})
        u_arch = rep.get("ARCH", "-")
        mtype = rep.get("MACHINE_TYPE", "-")
        prov = rep.get("PROVISIONING", "-")
        cpu_model = rep.get("CPU_MODEL", "-")
        if cpu_model == "Arm64 (0x41/0xd8e)":
            cpu_model = "Google Axion (Arm Neoverse-N3 0x41/0xd8e)"
        if u_arch == "aarch64":
            arch_disp = f"{GREEN}{u_arch:<16}{RESET}"
        elif u_arch == "x86_64":
            arch_disp = f"{YELLOW}{u_arch:<16}{RESET}"
        else:
            arch_disp = f"{u_arch:<16}"
        print(f"  {pname:<36} {phase:<14} {arch_disp} {mtype:<16} {prov:<8} {nname:<50} {cpu_model}")
PY
}

if [[ "${ONCE}" == "true" ]]; then
  render_snapshot
  exit 0
fi

while true; do
  clear
  render_snapshot
  sleep "${WATCH_INTERVAL}"
done
