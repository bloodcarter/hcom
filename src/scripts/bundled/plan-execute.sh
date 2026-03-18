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

Spawns two agents:
  IMPLEMENTER: Builds each phase of the plan
  AUDITOR: Independently verifies each phase against the plan file

The auditor has veto power. FAIL = implementer must fix. PARTIAL = FAIL.
Only the human (bigboss) can override an auditor FAIL.

Options:
  --plan PATH             Path to the approved plan file (required)
  --name NAME             Your hcom identity
  --tool TOOL             AI tool for agents (default: claude)
  --impl-tool TOOL        Override tool for implementer only
  --audit-tool TOOL       Override tool for auditor only
  --max-retries N         Max fix attempts per phase before escalating (default: 3)
  --branch NAME           Git branch for implementation (default: auto-created)
  --dir PATH              Working directory (default: current)
  -h, --help              Show this help

Examples:
  hcom run plan-execute --plan docs/plans/my-feature.md
  hcom run plan-execute --plan docs/plans/refactor.md --max-retries 5
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
branch=""
work_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --plan) plan_path="$2"; shift 2 ;;
    --name) name_flag="$2"; shift 2 ;;
    --tool) tool="$2"; shift 2 ;;
    --impl-tool) impl_tool="$2"; shift 2 ;;
    --audit-tool) audit_tool="$2"; shift 2 ;;
    --max-retries) max_retries="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
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

# Resolve caller
name_arg=""
[[ -n "$name_flag" ]] && name_arg="--name $name_flag"

caller_name=""
caller_json=$(hcom list self --json $name_arg 2>/dev/null) && {
  caller_name=$(echo "$caller_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])" 2>/dev/null)
} || caller_name="bigboss"

# Resolve absolute plan path
plan_abs=$(realpath "$plan_path")

# Batch ID for coordinated cleanup
batch_id="plan-exec-$(date +%s)"

# Dir flags
dir_flag=""
[[ -n "$work_dir" ]] && dir_flag="-C $work_dir"

trap cleanup ERR

# --- Launch Implementer ---

impl_system="You are the IMPLEMENTER in a plan-execute workflow.

YOUR JOB: Build each phase of the approved plan. You will receive one phase at a time.

RULES:
1. Read the plan file at: ${plan_abs}
2. Implement EXACTLY what the plan says. Do not simplify, substitute, or skip requirements.
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

Start by reading the plan file and waiting for your first phase assignment."

impl_prompt="Read the plan file at ${plan_abs} and wait for your phase assignment via hcom."

echo "Launching implementer (${impl_tool})..." >&2
launch_out=$(hcom 1 "$impl_tool" --tag plan-impl --go \
  --batch-id "$batch_id" \
  --hcom-system-prompt "$impl_system" \
  --hcom-prompt "$impl_prompt" \
  $dir_flag 2>&1) || {
  echo "Error: Failed to launch implementer" >&2
  exit 1
}
track_launch "$launch_out"

impl_name=$(echo "$launch_out" | grep '^Names: ' | sed 's/^Names: //' | tr -d ' ')
echo "  Implementer: $impl_name" >&2

# --- Launch Auditor ---

audit_system="You are the PLAN COMPLIANCE AUDITOR in a plan-execute workflow.

YOUR JOB: Independently verify that each phase implementation matches the approved plan.
You have VETO POWER. Your FAIL means the implementer must fix. Only bigboss can override you.

RULES:
1. The approved plan is at: ${plan_abs}
2. You will receive audit requests with a phase name.
3. For each audit:
   a. Read the plan file — extract the EXACT requirements for that phase
   b. Read the actual code/files that were created or modified (use git diff, file reads, etc.)
   c. For EACH requirement: produce PASS or FAIL with specific evidence
   d. PARTIAL is NOT acceptable — either the requirement is fully met or it is FAIL
4. Report your findings via hcom with EXACTLY this format:
   hcom send '@plan-exec-ctrl' --intent inform -- 'AUDIT_RESULT: <phase_name>
   VERDICT: PASS|FAIL
   <requirement 1>: PASS|FAIL — <evidence>
   <requirement 2>: PASS|FAIL — <evidence>
   ...'
5. You do NOT evaluate code quality, style, or architecture. Only plan compliance.
6. You read the plan DIRECTLY. You never rely on the implementer's summary of what the plan says.
7. Be literal. If the plan says 'Docker', a Jest mock is FAIL even if it's well-written.

You are the structural check against convenience bias and incremental drift.
Your independence is the reason this workflow is trustworthy.

Wait for audit requests."

audit_prompt="Read the plan file at ${plan_abs} to familiarize yourself with its structure, then wait for audit requests via hcom."

echo "Launching auditor (${audit_tool})..." >&2
launch_out=$(hcom 1 "$audit_tool" --tag plan-audit --go \
  --batch-id "$batch_id" \
  --hcom-system-prompt "$audit_system" \
  --hcom-prompt "$audit_prompt" \
  $dir_flag 2>&1) || {
  echo "Error: Failed to launch auditor" >&2
  exit 1
}
track_launch "$launch_out"

audit_name=$(echo "$launch_out" | grep '^Names: ' | sed 's/^Names: //' | tr -d ' ')
echo "  Auditor: $audit_name" >&2

# --- Controller Identity ---

# Start controller identity for message routing
hcom start --as plan-exec-ctrl $name_arg 2>/dev/null || true

# Subscribe to messages from both agents
hcom events sub --idle "$impl_name" $name_arg 2>/dev/null || true
hcom events sub --idle "$audit_name" $name_arg 2>/dev/null || true

# Clear trap (successful launch)
trap - ERR

# --- Phase Extraction ---

# Extract phase/section names from the plan file
# Looks for ## headers or numbered sections
extract_phases() {
  local plan="$1"
  python3 -c "
import re, sys

with open('$plan') as f:
    content = f.read()

# Find phase/step/section headers (## Phase N, ## Step N, numbered items, etc.)
phases = []
for m in re.finditer(r'^##\s+(Phase\s+\d+|Step\s+\d+|Stage\s+\d+)[:\s—–-]*(.*)', content, re.MULTILINE | re.IGNORECASE):
    name = m.group(1).strip()
    desc = m.group(2).strip(' :—–-')
    phases.append(f'{name}: {desc}' if desc else name)

# If no Phase/Step headers, try numbered top-level items
if not phases:
    for m in re.finditer(r'^#+\s+(\d+[\.\)]\s+.+)', content, re.MULTILINE):
        phases.append(m.group(1).strip())

# If still nothing, use all ## headers
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
echo "Starting execution..." >&2

# --- Execution Loop ---

total_phases=${#phases[@]}
completed=0

for i in "${!phases[@]}"; do
  phase="${phases[$i]}"
  phase_num=$((i+1))
  retries=0

  echo "" >&2
  echo "=== Phase ${phase_num}/${total_phases}: ${phase} ===" >&2

  # Send phase assignment to implementer
  hcom send "@${impl_name}" $name_arg --intent request -- \
    "PHASE ASSIGNMENT: ${phase}

Read the plan file at ${plan_abs} and implement this phase.
Extract the EXACT requirements for this phase from the plan.
Implement each one literally — do not simplify or substitute.

When done, report: hcom send '@plan-exec-ctrl' --intent inform -- 'PHASE_DONE: ${phase}'

If you cannot meet a requirement, report PHASE_BLOCKED with the specific requirement and why." 2>/dev/null

  echo "  Assigned to implementer" >&2

  # Wait for PHASE_DONE or PHASE_BLOCKED
  while true; do
    # Listen for messages (controller waits here)
    msg=$(hcom listen --timeout 300 --json $name_arg 2>/dev/null) || {
      echo "  Timeout waiting for implementer (5 min). Nudging..." >&2
      hcom send "@${impl_name}" $name_arg --intent request -- \
        "Status check: are you still working on phase '${phase}'? Report progress." 2>/dev/null
      continue
    }

    # Parse the message
    msg_text=$(echo "$msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # Handle both direct message and event wrapper formats
    if 'text' in d:
        print(d['text'])
    elif 'data' in d and 'text' in d['data']:
        print(d['data']['text'])
    else:
        print('')
except:
    print('')
" 2>/dev/null)

    msg_from=$(echo "$msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'from' in d:
        print(d['from'])
    elif 'data' in d and 'from' in d['data']:
        print(d['data']['from'])
    else:
        print('')
except:
    print('')
" 2>/dev/null)

    # Skip event notifications and system messages
    if [[ "$msg_from" == "[hcom-events]" ]] || [[ -z "$msg_text" ]]; then
      continue
    fi

    # Check for PHASE_DONE from implementer
    if echo "$msg_text" | grep -q "PHASE_DONE"; then
      echo "  Implementer reports phase done. Triggering audit..." >&2

      # Send audit request to auditor
      hcom send "@${audit_name}" $name_arg --intent request -- \
        "AUDIT REQUEST: ${phase}

Read the plan file at ${plan_abs}. Extract the EXACT requirements for: ${phase}

Read the actual code changes (git diff, read files, check what was built).

For EACH requirement: PASS or FAIL with specific evidence. PARTIAL = FAIL.

Report format:
hcom send '@plan-exec-ctrl' --intent inform -- 'AUDIT_RESULT: ${phase}
VERDICT: PASS|FAIL
<requirement>: PASS|FAIL — <evidence>
...'" 2>/dev/null

      echo "  Audit requested" >&2

      # Wait for audit result
      while true; do
        audit_msg=$(hcom listen --timeout 300 --json $name_arg 2>/dev/null) || {
          echo "  Timeout waiting for auditor. Nudging..." >&2
          hcom send "@${audit_name}" $name_arg --intent request -- \
            "Status check: audit for phase '${phase}' — please report your findings." 2>/dev/null
          continue
        }

        audit_text=$(echo "$audit_msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'text' in d:
        print(d['text'])
    elif 'data' in d and 'text' in d['data']:
        print(d['data']['text'])
    else:
        print('')
except:
    print('')
" 2>/dev/null)

        audit_from=$(echo "$audit_msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'from' in d:
        print(d['from'])
    elif 'data' in d and 'from' in d['data']:
        print(d['data']['from'])
    else:
        print('')
except:
    print('')
" 2>/dev/null)

        # Skip non-audit messages
        if [[ "$audit_from" == "[hcom-events]" ]] || [[ -z "$audit_text" ]]; then
          continue
        fi

        if echo "$audit_text" | grep -q "AUDIT_RESULT"; then
          if echo "$audit_text" | grep -q "VERDICT: PASS"; then
            echo "  AUDIT PASSED" >&2
            completed=$((completed + 1))
            break 2  # Break both inner loops, continue to next phase
          else
            retries=$((retries + 1))
            echo "  AUDIT FAILED (attempt ${retries}/${max_retries})" >&2

            if [[ $retries -ge $max_retries ]]; then
              echo "" >&2
              echo "  MAX RETRIES REACHED for phase: ${phase}" >&2
              echo "  Escalating to bigboss..." >&2

              # Notify bigboss
              if [[ -n "$caller_name" && "$caller_name" != "bigboss" ]]; then
                hcom send "@${caller_name}" $name_arg --intent request -- \
                  "ESCALATION: Phase '${phase}' failed audit ${max_retries} times.

Last audit result:
${audit_text}

Options:
1. Allow another retry cycle
2. Override auditor FAIL and proceed
3. Modify the plan requirements
4. Abort plan execution

Respond with your decision." 2>/dev/null
              fi

              echo "  Waiting for bigboss decision..." >&2

              # Wait for bigboss decision
              while true; do
                boss_msg=$(hcom listen --timeout 600 --json $name_arg 2>/dev/null) || {
                  echo "  Still waiting for bigboss (10 min timeout)..." >&2
                  continue
                }
                boss_text=$(echo "$boss_msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'text' in d: print(d['text'])
    elif 'data' in d and 'text' in d['data']: print(d['data']['text'])
    else: print('')
except: print('')
" 2>/dev/null)
                boss_from=$(echo "$boss_msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'from' in d: print(d['from'])
    elif 'data' in d and 'from' in d['data']: print(d['data']['from'])
    else: print('')
except: print('')
" 2>/dev/null)

                if [[ "$boss_from" == "[hcom-events]" ]] || [[ -z "$boss_text" ]]; then
                  continue
                fi

                # Process bigboss decision
                if echo "$boss_text" | grep -iq "override\|proceed\|skip\|accept"; then
                  echo "  Bigboss: override — proceeding to next phase" >&2
                  completed=$((completed + 1))
                  break 3  # Break all loops, next phase
                elif echo "$boss_text" | grep -iq "retry\|again\|continue"; then
                  echo "  Bigboss: retry — resetting retry counter" >&2
                  retries=0
                  break  # Break boss loop, send failures to implementer
                elif echo "$boss_text" | grep -iq "abort\|stop\|cancel"; then
                  echo "  Bigboss: abort" >&2
                  echo "" >&2
                  echo "=== PLAN EXECUTION ABORTED ===" >&2
                  echo "Completed: ${completed}/${total_phases} phases" >&2
                  cleanup
                  exit 1
                else
                  echo "  Unrecognized decision. Reply with: retry, override, or abort" >&2
                fi
              done
            fi

            # Send failures to implementer for fixing
            hcom send "@${impl_name}" $name_arg --intent request -- \
              "AUDIT FAILED for phase: ${phase} (attempt ${retries}/${max_retries})

Auditor findings:
${audit_text}

Fix ALL FAIL items. Each requirement must be met LITERALLY as stated in the plan.
Do not substitute alternatives. If you cannot meet a requirement, report PHASE_BLOCKED.

When fixed, report: hcom send '@plan-exec-ctrl' --intent inform -- 'PHASE_DONE: ${phase}'" 2>/dev/null

            echo "  Sent failures to implementer for fixing" >&2
            break  # Break audit loop, wait for next PHASE_DONE
          fi
        fi
      done
      # Continue waiting for implementer's fix (outer while loop)
      continue
    fi

    # Check for PHASE_BLOCKED from implementer
    if echo "$msg_text" | grep -q "PHASE_BLOCKED"; then
      echo "" >&2
      echo "  PHASE BLOCKED: ${phase}" >&2
      echo "  Reason: ${msg_text}" >&2
      echo "  Escalating to bigboss..." >&2

      if [[ -n "$caller_name" && "$caller_name" != "bigboss" ]]; then
        hcom send "@${caller_name}" $name_arg --intent request -- \
          "BLOCKED: Implementer cannot complete phase '${phase}'.

Reason: ${msg_text}

Options:
1. Provide guidance and retry
2. Modify the plan
3. Skip this phase
4. Abort" 2>/dev/null
      fi

      # Wait for decision (same logic as escalation)
      while true; do
        boss_msg=$(hcom listen --timeout 600 --json $name_arg 2>/dev/null) || continue
        boss_text=$(echo "$boss_msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'text' in d: print(d['text'])
    elif 'data' in d and 'text' in d['data']: print(d['data']['text'])
    else: print('')
except: print('')
" 2>/dev/null)
        boss_from=$(echo "$boss_msg" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'from' in d: print(d['from'])
    elif 'data' in d and 'from' in d['data']: print(d['data']['from'])
    else: print('')
except: print('')
" 2>/dev/null)
        if [[ "$boss_from" == "[hcom-events]" ]] || [[ -z "$boss_text" ]]; then
          continue
        fi
        if echo "$boss_text" | grep -iq "skip\|proceed\|override"; then
          echo "  Bigboss: skip phase" >&2
          break 2
        elif echo "$boss_text" | grep -iq "abort\|stop\|cancel"; then
          echo "  Bigboss: abort" >&2
          cleanup
          exit 1
        else
          # Forward guidance to implementer
          hcom send "@${impl_name}" $name_arg --intent request -- \
            "Bigboss guidance for blocked phase '${phase}': ${boss_text}

Try again. When done: hcom send '@plan-exec-ctrl' --intent inform -- 'PHASE_DONE: ${phase}'" 2>/dev/null
          break  # Back to waiting for PHASE_DONE
        fi
      done
    fi
  done
done

# --- Completion ---

echo "" >&2
echo "=== PLAN EXECUTION COMPLETE ===" >&2
echo "Completed: ${completed}/${total_phases} phases" >&2
echo "Plan: ${plan_abs}" >&2

# Final summary to bigboss
if [[ -n "$caller_name" && "$caller_name" != "bigboss" ]]; then
  hcom send "@${caller_name}" $name_arg --intent inform -- \
    "PLAN EXECUTION COMPLETE: ${completed}/${total_phases} phases passed audit.
Plan: ${plan_abs}
All audited phases have independent PASS verification." 2>/dev/null
fi

# Cleanup agents
echo "Stopping agents..." >&2
for name in "${LAUNCHED_NAMES[@]}"; do
  hcom stop "$name" --go 2>/dev/null || true
done

echo "Done." >&2
