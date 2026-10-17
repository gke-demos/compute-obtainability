#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

README_FILE="${REPO_ROOT}/README.md"
BLOG_FILE="${REPO_ROOT}/BLOG.md"
TROUBLESHOOTING_FILE="${REPO_ROOT}/TROUBLESHOOTING.md"
MP4_FILE="${REPO_ROOT}/assets/demo.mp4"
GIF_FILE="${REPO_ROOT}/assets/demo.gif"

log() {
  printf "\033[1;34m[test-docs]\033[0m %s\n" "$*"
}

pass() {
  printf "\033[1;32m[PASS]\033[0m %s\n" "$*"
}

fail() {
  printf "\033[1;31m[FAIL]\033[0m %s\n" "$*" >&2
  exit 1
}

log "Step 1: Checking required documentation and video files exist and are non-empty..."
for f in "${README_FILE}" "${BLOG_FILE}" "${TROUBLESHOOTING_FILE}" "${MP4_FILE}" "${GIF_FILE}"; do
  [[ -s "${f}" ]] || fail "Missing or empty required artifact: ${f}"
done
pass "All required documentation files (README.md, BLOG.md, TROUBLESHOOTING.md) and media assets (assets/demo.mp4, assets/demo.gif) exist."

log "Step 2: Checking public terminology hygiene across the entire repository..."
BANNED_TERM="fluid"" compute"
MATCHES="$(grep -ri --exclude-dir=.git "${BANNED_TERM}" "${REPO_ROOT}" || true)"
if [[ -n "${MATCHES}" ]]; then
  echo "${MATCHES}" >&2
  fail "Found banned internal phrase in repository files"
fi
pass "Zero occurrences of internal-only terminology across the entire repository."

log "Step 3: Validating README.md, BLOG.md, and TROUBLESHOOTING.md content, domain glossary terms, and humanizer rules..."
python3 - "${README_FILE}" "${BLOG_FILE}" "${TROUBLESHOOTING_FILE}" <<'PY'
import re
import sys

readme_path, blog_path, ts_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(readme_path, "r", encoding="utf-8") as f:
    readme = f.read()
with open(blog_path, "r", encoding="utf-8") as f:
    blog = f.read()
with open(ts_path, "r", encoding="utf-8") as f:
    ts = f.read()

def strip_code(md: str) -> str:
    # Remove fenced code blocks
    no_fenced = re.sub(r"```.*?```", "", md, flags=re.DOTALL)
    # Remove inline code
    no_inline = re.sub(r"`[^`]+`", "", no_fenced)
    return no_inline

for name, content in [("README.md", readme), ("BLOG.md", blog), ("TROUBLESHOOTING.md", ts)]:
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

# Verify canonical GLOSSARY.md terms in README.md and BLOG.md
canonical_terms = [
    "Compute Obtainability",
    "Obtainability Ladder",
    "Architecture Taint Suppression",
    "Fail-Fast Reservation Affinity",
    "Active Migration",
    "Node Pool Auto-Creation",
    "Silicon Inspector",
]
for name, content in [("README.md", readme), ("BLOG.md", blog)]:
    for term in canonical_terms:
        assert re.search(re.escape(term), content, re.IGNORECASE), f"{name} missing canonical glossary term '{term}'"
    assert "```mermaid" in content, f"{name} missing Mermaid architecture diagram"

# Verify README.md quickstart commands & core ComputeClass concepts
for item in (
    "make apply",
    "make status",
    "make unlock-arm",
    "make watch",
    "make clean",
    "architectureTaintBehavior: NONE",
    "AnyThenFail",
    "optimizeRulePriority: true",
):
    assert item in readme, f"README.md missing required item '{item}'"

# Verify BLOG.md embeds demo.gif, links to demo.mp4, includes empirical timeline table, and 3-point closing section
assert "![GKE 1.37 Designing for Obtainability Live Demo](assets/demo.gif)" in blog, (
    "BLOG.md missing ![GKE 1.37 Designing for Obtainability Live Demo](assets/demo.gif)"
)
assert "assets/demo.mp4" in blog, "BLOG.md missing link to assets/demo.mp4"

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
    assert empirical_fact in blog, f"BLOG.md missing required empirical detail or link '{empirical_fact}'"

# Verify TROUBLESHOOTING.md covers the 3 production lessons
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
    "0001-architecture-taint-none-over-pod-tolerations.md",
    "0002-anythenfail-reservation-for-deterministic-fallback-and-active-migration.md",
    "0003-in-place-active-migration-and-defrag-lifecycle.md",
):
    assert ts_item in ts, f"TROUBLESHOOTING.md missing required topic '{ts_item}'"
PY
pass "README.md, BLOG.md, and TROUBLESHOOTING.md content, glossary terms, and humanizer rules verified."

log "Step 4: Verifying assets/demo.mp4 and assets/demo.gif video streams with ffprobe..."
MP4_INFO="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,duration -of default=noprint_wrappers=1 "${MP4_FILE}")"
echo "${MP4_INFO}"
grep -q "^codec_name=h264$" <<<"${MP4_INFO}" || fail "assets/demo.mp4 must use h264 video codec"
grep -q "^width=1440$" <<<"${MP4_INFO}" || fail "assets/demo.mp4 must have width=1440 (macOS Sonoma frame)"
grep -q "^height=940$" <<<"${MP4_INFO}" || fail "assets/demo.mp4 must have height=940 (macOS Sonoma frame)"

GIF_INFO="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height -of default=noprint_wrappers=1 "${GIF_FILE}")"
echo "${GIF_INFO}"
grep -q "^codec_name=gif$" <<<"${GIF_INFO}" || fail "assets/demo.gif must be a valid GIF"
pass "assets/demo.mp4 and assets/demo.gif verified."

pass "All Ticket #4 documentation and demo video checks passed!"
