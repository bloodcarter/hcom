#!/usr/bin/env bash
# Autonomous plan execution with independent compliance auditing.
#
# Spawns an implementer and an auditor. The implementer builds each phase.
# After each phase claim, the auditor independently reads the plan file and
# the code, produces PASS/FAIL per requirement. FAIL = implementer must fix.
# Only bigboss (human) can override an auditor FAIL.
#
# The script controls the gate — neither agent can subvert the workflow.
#
# Usage:
#   hcom run plan-execute --plan docs/plans/foo.md
#   hcom run plan-execute --plan docs/plans/foo.md --tool codex
#   hcom run plan-execute --plan docs/plans/foo.md --max-retries 5

set -euo pipefail

LAUNCHED_NAMES=()
cleanup() {
  if [[ ${#LAUNCHED_NAMES[@]} -gt 0 ]]; then
    echo "Cleaning up ${#LAUNCHED_NAMES[@]} launched agents..." >&2
    for name in "${LAUNCHED_NAMES[@]}"; do
      hcom stop "$name" --go 2>/dev/null || true
    done
  fi
}
track_launch() {
  local output="$1"
  local names
  names=$(echo "$output" | grep '^Names: ' | sed 's/^Names: //' | tr ',' '\n' | xargs)
  for n in $names; do
    LAUNCHED_NAMES+=("$n")
  done
}

usage() {
  cat <<'EOF'
Usage: hcom run plan-execute [OPTIONS]

Execute an approved plan with independent compliance auditing.

Spawns two agents in terminal windows:
  IMPLEMENTER: Builds each phase of the plan
  AUDITOR: Independently verifies each phase against the plan file

The auditor has veto power. FAIL = implementer must fix. PARTIAL = FAIL.
Only the human (bigboss) can override an auditor FAIL.

Options:
  --plan PATH             Path to the approved plan file (required)
  --start-phase N         Start from phase N, skipping earlier phases (default: 1)
  --name NAME             Your hcom identity
  --tool TOOL             AI tool for agents (default: claude)
  --impl-tool TOOL        Override tool for implementer only
  --audit-tool TOOL       Override tool for auditor only
  --max-retries N         Max fix attempts per phase before escalating (default: 3)
  --dir PATH              Working directory (default: current)
  -h, --help              Show this help

Examples:
  hcom run plan-execute --plan docs/plans/my-feature.md
  hcom run plan-execute --plan docs/plans/refactor.md --start-phase 3
  hcom run plan-execute --plan docs/plans/v2.md --impl-tool claude --audit-tool codex
EOF
  exit 0
}

# Parse args
plan_path=""
name_flag=""
tool="claude"
impl_tool=""
audit_tool=""
max_retries=3
start_phase=1
work_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --plan) plan_path="$2"; shift 2 ;;
    --start-phase) start_phase="$2"; shift 2 ;;
    --name) name_flag="$2"; shift 2 ;;
    --tool) tool="$2"; shift 2 ;;
    --impl-tool) impl_tool="$2"; shift 2 ;;
    --audit-tool) audit_tool="$2"; shift 2 ;;
    --max-retries) max_retries="$2"; shift 2 ;;
    --dir) work_dir="$2"; shift 2 ;;
    -*) echo "Error: unknown option: $1" >&2; exit 1 ;;
    *) echo "Error: unexpected argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$plan_path" ]]; then
  echo "Error: --plan is required" >&2
  echo "Usage: hcom run plan-execute --plan <path>" >&2
  exit 1
fi

if [[ ! -f "$plan_path" ]]; then
  echo "Error: plan file not found: $plan_path" >&2
  exit 1
fi

# Resolve tools
[[ -z "$impl_tool" ]] && impl_tool="$tool"
[[ -z "$audit_tool" ]] && audit_tool="$tool"

# Build permission-bypass flags per tool type
skip_perms_flag() {
  case "$1" in
    claude) echo "--dangerously-skip-permissions" ;;
    codex)  echo "--full-auto" ;;
    *)      echo "" ;;
  esac
}
impl_skip=$(skip_perms_flag "$impl_tool")
audit_skip=$(skip_perms_flag "$audit_tool")

# Resolve absolute plan path
plan_abs=$(realpath "$plan_path")

# Batch ID for coordinated cleanup
batch_id="plan-exec-$(date +%s)"

# Dir flags
dir_flag=""
[[ -n "$work_dir" ]] && dir_flag="-C $work_dir"

# --- Controller Identity (before launching agents) ---
hcom start --as plan-exec-ctrl >/dev/null 2>&1 || true

trap cleanup ERR

# --- Launch Implementer ---

impl_system="You are the IMPLEMENTER in a plan-execute workflow.

YOUR JOB: Build each phase of the approved plan. You will receive one phase at a time.

RULES:
1. Read the plan file at: ${plan_abs}
2. Implement EXACTLY what the plan says. Do not simplify, substitute, or skip requirements.
   If the plan says 'copy verbatim', copy the file — do not rewrite it.
   If the plan says 'Docker + real Electron', build Docker + real Electron — do not substitute Jest mocks.
   If the plan says '~200 lines', aim for that — do not build a 1000-line reimplementation.
3. When you finish a phase, report completion via hcom with EXACTLY this format:
   hcom send '@plan-exec-ctrl' --intent inform -- 'PHASE_DONE: <phase_name>'
4. If the auditor rejects your work (FAIL), you will receive specific failures. Fix them and report again.
5. You CANNOT override the auditor. If you disagree, say so in your report — the human will decide.
6. Do NOT delegate to sub-agents without including the VERBATIM plan requirements from the plan file.
   If you delegate, copy the relevant plan section word-for-word into the delegation prompt.
7. Do NOT treat reviewer/sub-agent recommendations as authorization to deviate from the plan.
   Only the human (bigboss) can authorize plan changes.

CRITICAL: When you report PHASE_DONE, the auditor will independently read the plan file and your code.
They will check each requirement literally. PARTIAL = FAIL. Make sure every requirement is met before reporting.
The auditor checks SUBSTANCE, not just existence — files must actually do what the plan says, not just exist.

Start by reading the plan file and waiting for your first phase assignment."

impl_prompt="Read the plan file at ${plan_abs} and wait for your phase assignment via hcom."

echo "Launching implementer (${impl_tool})..." >&2
launch_out=$(hcom 1 "$impl_tool" --tag plan-impl --go \
  --batch-id "$batch_id" \
  --hcom-system-prompt "$impl_system" \
  --hcom-prompt "$impl_prompt" \
  $dir_flag $impl_skip 2>&1) || {
  echo "Error: Failed to launch implementer" >&2
  exit 1
}
track_launch "$launch_out"

impl_name=$(echo "$launch_out" | grep '^Names: ' | sed 's/^Names: //' | tr -d ' ')
echo "  Implementer: $impl_name" >&2

# Wait for implementer to be fully ready before launching auditor
for _i in $(seq 1 30); do
  status=$(hcom list "$impl_name" --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null) || true
  [[ "$status" == "listening" || "$status" == "active" ]] && break
  sleep 2
done

# --- Launch Auditor ---

audit_system="You are the PLAN COMPLIANCE AUDITOR in a plan-execute workflow.

YOUR JOB: Independently verify that each phase implementation matches the approved plan.
You have VETO POWER. Your FAIL means the implementer must fix. Only bigboss can override you.

CRITICAL AUDIT METHODOLOGY — check SUBSTANCE, not just existence:

For EVERY requirement, you must verify the ACTUAL BEHAVIOR, not just that a file exists:

- 'Copy verbatim' means diff the files — if the content differs materially, it's FAIL (not 'rewritten')
- 'Run real Electron app in Docker' means the test ACTUALLY launches Electron inside a Docker container.
  If you find Jest tests with mock providers or a headless Node.js script, that is FAIL even if the file
  is named 'e2e' and lives in a Docker directory.
- 'Feed real audio via PulseAudio' means actual PulseAudio virtual mic setup. No audio = FAIL.
- '~200 lines' is a guideline, not exact — but if the plan says ~200 and you find 1000, investigate why.
- 'No repair loops' means grep for retry/repair patterns — verify their absence, don't trust filenames.
- 'Record fixtures from manual sessions' means the fixtures were captured from real LLM calls, not hand-written.

HOW TO AUDIT each requirement:
1. Read the plan file at ${plan_abs} — extract the EXACT words used for this phase
2. Read the actual code — not just filenames but the CONTENT of the files
3. For 'copy' requirements: diff the v1 and v2 files
4. For 'build X' requirements: read the file, verify it does what the plan describes
5. For testing requirements: read the test code and verify it tests the REAL code path, not a mock/stub
6. For 'wire into X' requirements: trace the actual integration point

REPORT FORMAT — use EXACTLY this:
hcom send '@plan-exec-ctrl' --intent inform -- 'AUDIT_RESULT: <phase_name>
VERDICT: PASS|FAIL
<requirement>: PASS|FAIL — <specific file:line evidence>'

VERDICT RULES:
- Use ONLY 'VERDICT: PASS' or 'VERDICT: FAIL'. Nothing else.
- NEVER use 'PASS (with caveats)', 'PARTIAL', 'PASS*', or any qualified pass.
- If ANY requirement is not fully met, the verdict is FAIL. Period.
- Caveats, notes, and observations go in the per-requirement evidence, not the verdict.
- The verdict is binary: every requirement met = PASS, anything else = FAIL.

When you say PASS, include the specific evidence (file path, line numbers, what you verified).
When you say FAIL, explain exactly what the plan requires vs what was actually built.

You are the last line of defense against convenience bias. Be thorough. Be literal. Be skeptical."

# For Codex: long prompts on CLI cause exit code 2. Write instructions to temp file.
audit_instructions_file=$(mktemp /tmp/plan-audit-instructions-XXXXXX.md)
cat > "$audit_instructions_file" <<AUDIT_EOF
${audit_system}
AUDIT_EOF

if [[ "$audit_tool" == "codex" ]]; then
  audit_launch_system=""
  audit_launch_prompt="You are a plan compliance auditor. Read your full instructions at ${audit_instructions_file} then read the plan at ${plan_abs}. Wait for audit requests via hcom."
else
  audit_launch_system="$audit_system"
  audit_launch_prompt="Read the plan file at ${plan_abs} to familiarize yourself with its structure and specific requirements. Note any requirements that need careful substantive verification (e.g., 'copy verbatim', 'real E2E in Docker', 'no repair loops'). Then wait for audit requests via hcom."
fi

echo "Launching auditor (${audit_tool})..." >&2
if [[ -n "$audit_launch_system" ]]; then
  launch_out=$(hcom 1 "$audit_tool" --tag plan-audit --go \
    --batch-id "$batch_id" \
    --hcom-system-prompt "$audit_launch_system" \
    --hcom-prompt "$audit_launch_prompt" \
    $dir_flag $audit_skip 2>&1) || {
    echo "Error: Failed to launch auditor" >&2
    exit 1
  }
else
  launch_out=$(hcom 1 "$audit_tool" --tag plan-audit --go \
    --batch-id "$batch_id" \
    --hcom-prompt "$audit_launch_prompt" \
    $dir_flag $audit_skip 2>&1) || {
    echo "Error: Failed to launch auditor" >&2
    exit 1
  }
fi
track_launch "$launch_out"

audit_name=$(echo "$launch_out" | grep '^Names: ' | sed 's/^Names: //' | tr -d ' ')
echo "  Auditor: $audit_name" >&2

# Subscribe to idle events
hcom events sub --idle "$impl_name" --name plan-exec-ctrl >/dev/null 2>&1 || true
hcom events sub --idle "$audit_name" --name plan-exec-ctrl >/dev/null 2>&1 || true

# Clear trap (successful launch)
trap - ERR

# --- Phase Extraction ---

extract_phases() {
  local plan="$1"
  python3 -c "
import re, sys

with open('$plan') as f:
    content = f.read()

phases = []
for m in re.finditer(r'^#{2,4}\s+(Phase\s+\d+|Step\s+\d+|Stage\s+\d+)[:\s\xc2\xa0\xe2\x80\x94\xe2\x80\x93-]*(.*)', content, re.MULTILINE | re.IGNORECASE):
    name = m.group(1).strip()
    desc = m.group(2).strip(' :\xe2\x80\x94\xe2\x80\x93-')
    desc = re.sub(r'\s*\(\d+\s+days?\)\s*$', '', desc).strip()
    phases.append(f'{name}: {desc}' if desc else name)

if not phases:
    for m in re.finditer(r'^#+\s+(\d+[\.\)]\s+.+)', content, re.MULTILINE):
        phases.append(m.group(1).strip())

if not phases:
    for m in re.finditer(r'^##\s+(.+)', content, re.MULTILINE):
        phases.append(m.group(1).strip())

for p in phases:
    print(p)
" 2>/dev/null
}

phases=()
while IFS= read -r line; do
  [[ -n "$line" ]] && phases+=("$line")
done < <(extract_phases "$plan_abs")

if [[ ${#phases[@]} -eq 0 ]]; then
  echo "Warning: Could not extract phases from plan. Sending entire plan as single phase." >&2
  phases=("Full Plan")
fi

echo "" >&2
echo "Plan: $plan_abs" >&2
echo "Phases found: ${#phases[@]}" >&2
for i in "${!phases[@]}"; do
  echo "  $((i+1)). ${phases[$i]}" >&2
done
echo "" >&2
if [[ $start_phase -gt 1 ]]; then
  echo "Starting from phase ${start_phase} (skipping earlier phases)..." >&2
else
  echo "Starting execution..." >&2
fi

# --- Execution Loop ---

total_phases=${#phases[@]}
completed=0
skipped=0

for i in "${!phases[@]}"; do
  phase="${phases[$i]}"
  phase_num=$((i+1))
  retries=0

  # Skip phases before start_phase
  if [[ $phase_num -lt $start_phase ]]; then
    echo "  Skipping phase ${phase_num}: ${phase} (already completed)" >&2
    skipped=$((skipped + 1))
    continue
  fi

  echo "" >&2
  echo "=== Phase ${phase_num}/${total_phases}: ${phase} ===" >&2

  # Send phase assignment to implementer
  hcom send "@${impl_name}" --name plan-exec-ctrl --intent request -- \
    "PHASE ASSIGNMENT: ${phase}

Read the plan file at ${plan_abs} and implement this phase.
Extract the EXACT requirements for this phase from the plan.
Implement each one literally — do not simplify or substitute.

When done, report: hcom send '@plan-exec-ctrl' --intent inform -- 'PHASE_DONE: ${phase}'

If you cannot meet a requirement, report PHASE_BLOCKED with the specific requirement and why." 2>&1 || true

  echo "  Assigned to implementer" >&2

  # Wait for PHASE_DONE or PHASE_BLOCKED
  while true; do
    # Quick check for already-queued messages first, then long wait
    msg=$(hcom listen 2 --json --name plan-exec-ctrl 2>/dev/null) || \
    msg=$(hcom listen --timeout 600 --json --name plan-exec-ctrl 2>/dev/null) || {
      echo "  Timeout waiting for implementer (10 min). Nudging..." >&2
      hcom send "@${impl_name}" --name plan-exec-ctrl --intent request -- \
        "Status check: are you still working on phase '${phase}'? Report progress." 2>/dev/null || true
      continue
    }

    msg_text=$(echo "$msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('text', '') or (d.get('data', {}).get('text', '')))
except: print('')
" 2>/dev/null)

    msg_from=$(echo "$msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('from', '') or (d.get('data', {}).get('from', '')))
except: print('')
" 2>/dev/null)

    # Skip event notifications and system messages
    [[ "$msg_from" == "[hcom-events]" || -z "$msg_text" ]] && continue

    # Check for PHASE_DONE
    if echo "$msg_text" | grep -q "PHASE_DONE"; then
      echo "  Implementer reports phase done. Triggering audit..." >&2

      # Send audit request
      hcom send "@${audit_name}" --name plan-exec-ctrl --intent request -- \
        "AUDIT REQUEST: ${phase}

Read the plan file at ${plan_abs}. Extract the EXACT requirements for: ${phase}

Then verify the SUBSTANCE of the implementation — read actual file contents, diff where the plan says 'copy', check that tests actually test the real code path (not mocks pretending to be E2E).

For EACH requirement: PASS or FAIL with specific file:line evidence. PARTIAL = FAIL.

Report:
hcom send '@plan-exec-ctrl' --intent inform -- 'AUDIT_RESULT: ${phase}
VERDICT: PASS|FAIL
<requirement>: PASS|FAIL — <evidence>
...'" 2>/dev/null || true

      echo "  Audit requested" >&2

      # Wait for audit result
      while true; do
        # Quick check for already-queued messages first, then long wait
        audit_msg=$(hcom listen 2 --json --name plan-exec-ctrl 2>/dev/null) || \
        audit_msg=$(hcom listen --timeout 600 --json --name plan-exec-ctrl 2>/dev/null) || {
          echo "  Timeout waiting for auditor. Nudging..." >&2
          hcom send "@${audit_name}" --name plan-exec-ctrl --intent request -- \
            "Status check: audit for phase '${phase}' — please report your findings." 2>/dev/null || true
          continue
        }

        audit_text=$(echo "$audit_msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('text', '') or (d.get('data', {}).get('text', '')))
except: print('')
" 2>/dev/null)

        audit_from=$(echo "$audit_msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('from', '') or (d.get('data', {}).get('from', '')))
except: print('')
" 2>/dev/null)

        [[ "$audit_from" == "[hcom-events]" || -z "$audit_text" ]] && continue

        if echo "$audit_text" | grep -q "AUDIT_RESULT"; then
          if echo "$audit_text" | grep -qP "^VERDICT: PASS\s*$"; then
            echo "  AUDIT PASSED" >&2
            completed=$((completed + 1))
            break 2
          else
            retries=$((retries + 1))
            echo "  AUDIT FAILED (attempt ${retries}/${max_retries})" >&2

            if [[ $retries -ge $max_retries ]]; then
              echo "" >&2
              echo "  MAX RETRIES REACHED for phase: ${phase}" >&2
              echo "  Escalating to bigboss..." >&2

              hcom send "@bigboss" --name plan-exec-ctrl --intent request -- \
                "ESCALATION: Phase '${phase}' failed audit ${max_retries} times.

Last audit result:
${audit_text}

Options: reply 'retry', 'override', or 'abort'." 2>/dev/null || true

              echo "  Waiting for bigboss decision..." >&2

              while true; do
                boss_msg=$(hcom listen --timeout 600 --json --name plan-exec-ctrl 2>/dev/null) || {
                  echo "  Still waiting for bigboss..." >&2
                  continue
                }
                boss_text=$(echo "$boss_msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('text', '') or (d.get('data', {}).get('text', '')))
except: print('')
" 2>/dev/null)
                boss_from=$(echo "$boss_msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('from', '') or (d.get('data', {}).get('from', '')))
except: print('')
" 2>/dev/null)

                [[ "$boss_from" == "[hcom-events]" || -z "$boss_text" ]] && continue

                if echo "$boss_text" | grep -iq "override\|proceed\|skip\|accept"; then
                  echo "  Bigboss: override — proceeding" >&2
                  completed=$((completed + 1))
                  break 3
                elif echo "$boss_text" | grep -iq "retry\|again\|continue"; then
                  echo "  Bigboss: retry" >&2
                  retries=0
                  break
                elif echo "$boss_text" | grep -iq "abort\|stop\|cancel"; then
                  echo "  Bigboss: abort" >&2
                  echo "=== PLAN EXECUTION ABORTED ===" >&2
                  echo "Completed: ${completed}/${total_phases} phases" >&2
                  cleanup
                  exit 1
                fi
              done
            fi

            # Send failures to implementer
            hcom send "@${impl_name}" --name plan-exec-ctrl --intent request -- \
              "AUDIT FAILED for phase: ${phase} (attempt ${retries}/${max_retries})

Auditor findings:
${audit_text}

Fix ALL FAIL items. Each requirement must be met LITERALLY as stated in the plan.
Do not substitute alternatives. If you cannot meet a requirement, report PHASE_BLOCKED.

When fixed, report: hcom send '@plan-exec-ctrl' --intent inform -- 'PHASE_DONE: ${phase}'" 2>/dev/null || true

            echo "  Sent failures to implementer" >&2
            break  # Back to waiting for PHASE_DONE
          fi
        fi
      done
      continue
    fi

    # Check for PHASE_BLOCKED
    if echo "$msg_text" | grep -q "PHASE_BLOCKED"; then
      echo "  PHASE BLOCKED: ${phase}" >&2
      echo "  ${msg_text}" >&2

      hcom send "@bigboss" --name plan-exec-ctrl --intent request -- \
        "BLOCKED: Phase '${phase}' — ${msg_text}

Reply 'skip', 'abort', or provide guidance." 2>/dev/null || true

      while true; do
        boss_msg=$(hcom listen --timeout 600 --json --name plan-exec-ctrl 2>/dev/null) || continue
        boss_text=$(echo "$boss_msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('text', '') or (d.get('data', {}).get('text', '')))
except: print('')
" 2>/dev/null)
        boss_from=$(echo "$boss_msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('from', '') or (d.get('data', {}).get('from', '')))
except: print('')
" 2>/dev/null)
        [[ "$boss_from" == "[hcom-events]" || -z "$boss_text" ]] && continue

        if echo "$boss_text" | grep -iq "skip\|proceed\|override"; then
          break 2
        elif echo "$boss_text" | grep -iq "abort\|stop\|cancel"; then
          cleanup; exit 1
        else
          hcom send "@${impl_name}" --name plan-exec-ctrl --intent request -- \
            "Bigboss guidance: ${boss_text}

Try again. Report: hcom send '@plan-exec-ctrl' --intent inform -- 'PHASE_DONE: ${phase}'" 2>/dev/null || true
          break
        fi
      done
    fi
  done
done

# --- Completion ---

echo "" >&2
echo "=== PLAN EXECUTION COMPLETE ===" >&2
echo "Completed: ${completed}/${total_phases} phases (${skipped} skipped)" >&2
echo "Plan: ${plan_abs}" >&2

hcom send "@bigboss" --name plan-exec-ctrl --intent inform -- \
  "PLAN EXECUTION COMPLETE: ${completed}/${total_phases} phases passed audit.
Plan: ${plan_abs}
All audited phases have independent PASS verification." 2>/dev/null || true

# Cleanup
echo "Stopping agents..." >&2
for name in "${LAUNCHED_NAMES[@]}"; do
  hcom stop "$name" --go 2>/dev/null || true
done
echo "Done." >&2
