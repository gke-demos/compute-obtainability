#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_PREFIX="test-docs"
# shellcheck source=hack/lib.sh
source "${SCRIPT_DIR}/lib.sh"

README_FILE="${REPO_ROOT}/README.md"
BLOG1_FILE="${REPO_ROOT}/BLOG-01-MULTI-ARCH.md"
BLOG2_FILE="${REPO_ROOT}/BLOG-02-STATEFUL-STORAGE.md"
TROUBLESHOOTING_FILE="${REPO_ROOT}/TROUBLESHOOTING.md"
MP4_1_FILE="${REPO_ROOT}/assets/01-multi-arch-demo.mp4"
GIF_1_FILE="${REPO_ROOT}/assets/01-multi-arch-demo.gif"
MP4_2_FILE="${REPO_ROOT}/assets/02-stateful-storage-demo.mp4"
GIF_2_FILE="${REPO_ROOT}/assets/02-stateful-storage-demo.gif"

log "Step 1: Checking required documentation and video files exist and are non-empty..."
for f in \
  "${README_FILE}" \
  "${BLOG1_FILE}" \
  "${BLOG2_FILE}" \
  "${TROUBLESHOOTING_FILE}" \
  "${MP4_1_FILE}" \
  "${GIF_1_FILE}" \
  "${MP4_2_FILE}" \
  "${GIF_2_FILE}"; do
  [[ -s "${f}" ]] || fail "Missing or empty required artifact: ${f}"
done
pass "All required documentation files (README.md, BLOG-01-MULTI-ARCH.md, BLOG-02-STATEFUL-STORAGE.md, TROUBLESHOOTING.md) and media assets (01-multi-arch-demo.{mp4,gif}, 02-stateful-storage-demo.{mp4,gif}) exist."

log "Step 2: Checking public terminology hygiene across the entire repository..."
check_no_banned_terms "${REPO_ROOT}"
pass "Zero occurrences of internal-only terminology across the entire repository."

log "Step 3: Validating README.md, BLOG-01-MULTI-ARCH.md, BLOG-02-STATEFUL-STORAGE.md, and TROUBLESHOOTING.md content, domain glossary terms, and humanizer rules..."
python3 - "${README_FILE}" "${BLOG1_FILE}" "${BLOG2_FILE}" "${TROUBLESHOOTING_FILE}" <<'PY'
import re
import sys

readme_path, blog1_path, blog2_path, ts_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(readme_path, "r", encoding="utf-8") as f:
    readme = f.read()
with open(blog1_path, "r", encoding="utf-8") as f:
    blog1 = f.read()
with open(blog2_path, "r", encoding="utf-8") as f:
    blog2 = f.read()
with open(ts_path, "r", encoding="utf-8") as f:
    ts = f.read()

def strip_code(md: str) -> str:
    # Remove fenced code blocks
    no_fenced = re.sub(r"```.*?```", "", md, flags=re.DOTALL)
    # Remove inline code
    no_inline = re.sub(r"`[^`]+`", "", no_fenced)
    return no_inline

for name, content in [
    ("README.md", readme),
    ("BLOG-01-MULTI-ARCH.md", blog1),
    ("BLOG-02-STATEFUL-STORAGE.md", blog2),
    ("TROUBLESHOOTING.md", ts),
]:
    for marker in ("TODO", "TBD", "FIXME"):
        assert re.search(rf"\b{marker}\b", content) is None, f"{name} contains placeholder marker {marker}"

    prose = strip_code(content)
    assert "—" not in prose, f"{name} contains em-dash (—) in prose outside code blocks"
    assert "–" not in prose, f"{name} contains en-dash (–) in prose outside code blocks"
    assert " -- " not in prose, f"{name} contains spaced double-hyphen ( -- ) in prose outside code blocks"

    # Check humanizer banned AI patterns
    banned_patterns = [
        r"\bnot just\b.*?\bbut\b",
        r"\bnot only\b.*?\bbut\b",
        r"\bnot merely\b.*?\bbut\b",
        r"\blet's dive in\b",
        r"\bdelve\b",
        r"\btestament\b",
        r"\btapestry\b",
        r"\bpivotal\b",
        r"\bcrucial\b",
        r"\bread that again\b",
        r"\blet that sink in\b",
    ]
    for pat in banned_patterns:
        m = re.search(pat, prose, flags=re.IGNORECASE)
        assert m is None, f"{name} matched banned AI writing pattern '{pat}': {m.group(0)}"

# Verify Mermaid architecture diagrams in README.md, BLOG-01-MULTI-ARCH.md, and BLOG-02-STATEFUL-STORAGE.md
for name, content in [
    ("README.md", readme),
    ("BLOG-01-MULTI-ARCH.md", blog1),
    ("BLOG-02-STATEFUL-STORAGE.md", blog2),
]:
    assert "```mermaid" in content, f"{name} missing Mermaid architecture diagram"

# Verify canonical GLOSSARY.md terms in BLOG-01-MULTI-ARCH.md
blog1_terms = [
    "Compute Obtainability",
    "Obtainability Ladder",
    "Architecture Taint Suppression",
    "Fail-Fast Reservation Affinity",
    "Active Migration",
    "Node Pool Auto-Creation",
    "Silicon Inspector",
]
for term in blog1_terms:
    assert re.search(re.escape(term), blog1, re.IGNORECASE), f"BLOG-01-MULTI-ARCH.md missing canonical glossary term '{term}'"

# Verify canonical GLOSSARY.md terms in BLOG-02-STATEFUL-STORAGE.md
blog2_terms = [
    "Compute Obtainability",
    "Obtainability Ladder",
    "Fail-Fast Reservation Affinity",
    "Active Migration",
    "Node Pool Auto-Creation",
    "Dynamic Block Storage Selection",
    "PV Disk-Topology Pinning",
    "Storage Inspector",
]
for term in blog2_terms:
    assert re.search(re.escape(term), blog2, re.IGNORECASE), f"BLOG-02-STATEFUL-STORAGE.md missing canonical glossary term '{term}'"

# Verify README.md covers both Demo 01 and Demo 02 canonical terms and commands
readme_terms = blog1_terms + [
    "Dynamic Block Storage Selection",
    "PV Disk-Topology Pinning",
    "Storage Inspector",
]
for term in readme_terms:
    assert re.search(re.escape(term), readme, re.IGNORECASE), f"README.md missing canonical glossary term '{term}'"

for item in (
    "BLOG-01-MULTI-ARCH.md",
    "BLOG-02-STATEFUL-STORAGE.md",
    "assets/01-multi-arch-demo.gif",
    "assets/01-multi-arch-demo.mp4",
    "assets/02-stateful-storage-demo.gif",
    "assets/02-stateful-storage-demo.mp4",
    "make apply-multi-arch",
    "make unlock-arm",
    "make watch-multi-arch",
    "make apply-stateful",
    "make unlock-gen4",
    "make watch-stateful",
    "make status-stateful",
    "make logs-stateful",
    "make verify-stateful",
    "make clean",
    "architectureTaintBehavior: NONE",
    "AnyThenFail",
    "optimizeRulePriority: true",
    "dynamic-rwo",
):
    assert item in readme, f"README.md missing required item '{item}'"

# Verify BLOG-01-MULTI-ARCH.md embeds 01-multi-arch-demo.gif, links to 01-multi-arch-demo.mp4, includes empirical timeline table, and 3-point closing section
assert "![GKE 1.37 Designing for Obtainability Live Demo](assets/01-multi-arch-demo.gif)" in blog1, (
    "BLOG-01-MULTI-ARCH.md missing ![GKE 1.37 Designing for Obtainability Live Demo](assets/01-multi-arch-demo.gif)"
)
assert "assets/01-multi-arch-demo.mp4" in blog1, "BLOG-01-MULTI-ARCH.md missing link to assets/01-multi-arch-demo.mp4"

for empirical_fact in (
    "v1.37.0-gke.3503000",
    "n4d-highcpu-2",
    "AMD EPYC 9B45",
    "make unlock-arm",
    "n4a-highcpu-1",
    "Google Axion",
    "0x41",
    "0xd8e",
    "+137s",
    "+162s",
    "+178s",
    "+192s",
    "## A few things to keep in mind",
    "TROUBLESHOOTING.md",
    "0001-architecture-taint-none-over-pod-tolerations.md",
    "0002-anythenfail-reservation-for-deterministic-fallback-and-active-migration.md",
    "0003-in-place-active-migration-and-defrag-lifecycle.md",
):
    assert empirical_fact in blog1, f"BLOG-01-MULTI-ARCH.md missing required empirical detail or link '{empirical_fact}'"

# Verify BLOG-02-STATEFUL-STORAGE.md embeds 02-stateful-storage-demo.gif, links to 02-stateful-storage-demo.mp4, includes empirical timeline table, and 3-point closing section
assert "![GKE 1.37 Stateful Obtainability Live Demo](assets/02-stateful-storage-demo.gif)" in blog2, (
    "BLOG-02-STATEFUL-STORAGE.md missing ![GKE 1.37 Stateful Obtainability Live Demo](assets/02-stateful-storage-demo.gif)"
)
assert "assets/02-stateful-storage-demo.mp4" in blog2, "BLOG-02-STATEFUL-STORAGE.md missing link to assets/02-stateful-storage-demo.mp4"

for empirical_fact2 in (
    "v1.37.0-gke.3503000",
    "n2d-standard-2",
    "AMD EPYC 7B13",
    "pd-balanced",
    "n4d-highcpu-2",
    "AMD EPYC 9B45",
    "hyperdisk-balanced",
    "disk-type.gke.io/pd-balanced",
    "disk-type.gke.io/hyperdisk-balanced",
    "make unlock-gen4",
    "+59s",
    "+86s",
    "## A few things to keep in mind",
    "TROUBLESHOOTING.md",
    "0004-dynamic-rwo-and-pv-topology-pinning-across-vm-generations.md",
):
    assert empirical_fact2 in blog2, f"BLOG-02-STATEFUL-STORAGE.md missing required empirical detail or link '{empirical_fact2}'"

# Verify TROUBLESHOOTING.md covers all 4 production lessons (including Demo 02 stateful storage)
for ts_item in (
    "architectureTaintBehavior: NONE",
    "cloud.google.com/compute-class",
    "kubernetes.io/arch=arm64:NoSchedule",
    "AnyThenFail",
    "AnyBestEffort",
    "optimizeRulePriority: true",
    "consolidationDelayMinutes",
    "autoscaling.gke.io/defrag-candidate",
    "GKE_METADATA",
    "dynamic-rwo",
    "disk-type.gke.io/pd-balanced",
    "disk-type.gke.io/hyperdisk-balanced",
    "PV Disk-Topology Pinning",
    "podAntiAffinity",
    "0001-architecture-taint-none-over-pod-tolerations.md",
    "0002-anythenfail-reservation-for-deterministic-fallback-and-active-migration.md",
    "0003-in-place-active-migration-and-defrag-lifecycle.md",
    "0004-dynamic-rwo-and-pv-topology-pinning-across-vm-generations.md",
):
    assert ts_item in ts, f"TROUBLESHOOTING.md missing required topic '{ts_item}'"
PY
pass "README.md, BLOG-01-MULTI-ARCH.md, BLOG-02-STATEFUL-STORAGE.md, and TROUBLESHOOTING.md content, glossary terms, and humanizer rules verified."

log "Step 4: Verifying Demo 01 and Demo 02 MP4 (1440x940 H.264) and GIF (1100x718) media streams with ffprobe..."
for mp4 in "${MP4_1_FILE}" "${MP4_2_FILE}"; do
  MP4_INFO="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,duration -of default=noprint_wrappers=1 "${mp4}")"
  echo "--- ${mp4} ---"
  echo "${MP4_INFO}"
  grep -q "^codec_name=h264$" <<<"${MP4_INFO}" || fail "${mp4} must use h264 video codec"
  grep -q "^width=1440$" <<<"${MP4_INFO}" || fail "${mp4} must have width=1440 (macOS Sonoma frame)"
  grep -q "^height=940$" <<<"${MP4_INFO}" || fail "${mp4} must have height=940 (macOS Sonoma frame)"
done

for gif in "${GIF_1_FILE}" "${GIF_2_FILE}"; do
  GIF_INFO="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height -of default=noprint_wrappers=1 "${gif}")"
  echo "--- ${gif} ---"
  echo "${GIF_INFO}"
  grep -q "^codec_name=gif$" <<<"${GIF_INFO}" || fail "${gif} must be a valid GIF"
  grep -q "^width=1100$" <<<"${GIF_INFO}" || fail "${gif} must have width=1100"
  grep -q "^height=718$" <<<"${GIF_INFO}" || fail "${gif} must have height=718"
done
pass "Both Demo 01 and Demo 02 MP4 (1440x940) and GIF (1100x718) media assets verified."

pass "All Ticket #8 documentation and demo video checks passed!"
