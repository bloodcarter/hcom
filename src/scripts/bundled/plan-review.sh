#!/usr/bin/env bash
# Review an implementation plan for feasibility, contradictions, and intent alignment.
#
# Spawns a fatcow (codebase oracle) and a reviewer. The reviewer uses the fatcow
# to verify plan requirements against the actual codebase, checks for contradictions
# and ambiguity, and validates that the plan achieves the user's stated intent.
#
# The reviewer proposes fixes. Bigboss approves/rejects. Reviewer rewrites the plan.
#
# Usage:
#   hcom run plan-review --plan docs/plans/foo.md --codebase src/
#   hcom run plan-review --plan docs/plans/foo.md --codebase src/ --focus "auth,api"
#   hcom run plan-review --plan docs/plans/foo.md --codebase src/ --tool claude

set -euo pipefail

LAUNCHED_NAMES=()
# cleanup defined after keepalive_pid is set (see controller identity section)
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
Usage: hcom run plan-review [OPTIONS]

Review an implementation plan before execution.

Spawns a codebase oracle (fatcow) and a reviewer agent. The reviewer
checks each plan requirement for feasibility, contradictions, ambiguity,
and alignment with the user's stated intent. Proposes fixes for issues
found. Bigboss approves/rejects, reviewer rewrites the plan.

Options:
  --plan PATH          Plan file to review (required)
  --codebase PATH      Codebase directory for oracle (required)
  --focus TEXT          Comma-separated focus areas for oracle (optional)
  --tool TOOL          Reviewer tool (default: codex)
  --fatcow-tool TOOL   Oracle tool (default: claude)
  --dir PATH           Working directory (optional)
  -h, --help           Show this help

Examples:
  hcom run plan-review --plan docs/plans/my-feature.md --codebase src/
  hcom run plan-review --plan docs/plans/refactor.md --codebase src/ --focus "auth,api"
EOF
  exit 0
}

# Parse args
plan_path=""
codebase_path=""
focus=""
name_flag=""
tool="codex"
fatcow_tool="claude"
work_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --plan) plan_path="$2"; shift 2 ;;
    --codebase) codebase_path="$2"; shift 2 ;;
    --focus) focus="$2"; shift 2 ;;
    --name) name_flag="$2"; shift 2 ;;
    --tool) tool="$2"; shift 2 ;;
    --fatcow-tool) fatcow_tool="$2"; shift 2 ;;
    --dir) work_dir="$2"; shift 2 ;;
    -*) echo "Error: unknown option: $1" >&2; exit 1 ;;
    *) echo "Error: unexpected argument: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$plan_path" ]] && { echo "Error: --plan required" >&2; exit 1; }
[[ ! -f "$plan_path" ]] && { echo "Error: plan not found: $plan_path" >&2; exit 1; }
[[ -z "$codebase_path" ]] && { echo "Error: --codebase required" >&2; exit 1; }
[[ ! -d "$codebase_path" ]] && { echo "Error: codebase dir not found: $codebase_path" >&2; exit 1; }

plan_abs=$(realpath "$plan_path")
codebase_abs=$(realpath "$codebase_path")
dir_flag=""
[[ -n "$work_dir" ]] && dir_flag="-C $work_dir"

# Resolve caller identity (same pattern as confess/debate/fatcow)
name_arg=""
[[ -n "$name_flag" ]] && name_arg="--name $name_flag"

caller_json=$(hcom list self --json $name_arg 2>/dev/null) || {
  echo "Error: could not resolve identity. Run inside an hcom session or pass --name." >&2
  exit 1
}
caller_name=$(echo "$caller_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
echo "Controller: $caller_name" >&2

batch_id="plan-review-$(date +%s)"

cleanup() {
  if [[ ${#LAUNCHED_NAMES[@]} -gt 0 ]]; then
    echo "Cleaning up agents..." >&2
    for name in "${LAUNCHED_NAMES[@]}"; do
      hcom stop "$name" --go 2>/dev/null || true
    done
  fi
  [[ -n "${review_instructions_file:-}" ]] && rm -f "$review_instructions_file"
}

trap cleanup EXIT ERR

# --- Phase 0: Intent Gathering ---

echo "" >&2
echo "=== PLAN REVIEW ===" >&2
echo "Plan: $plan_abs" >&2
echo "Codebase: $codebase_abs" >&2
echo "" >&2
echo "Before the reviewer starts, describe your intent:" >&2
echo "  What problem does this plan solve?" >&2
echo "  What does success look like?" >&2
echo "  (Send via: hcom send @${caller_name} --intent inform -- 'your intent')" >&2
echo "  (Or type 'skip' if the plan file already describes the intent)" >&2
echo "" >&2

# Wait for bigboss intent statement
intent_text=""
intent_start_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
while true; do
  sleep 10
  intent_text=$(hcom events --type message --from bigboss --after "$intent_start_ts" --last 1 2>/dev/null \
    | python3 -c "import sys,json; d=json.loads(sys.stdin.readline().strip()); print(d.get('data',{}).get('text',''))" 2>/dev/null) || continue
  [[ -z "$intent_text" ]] && continue
  break
done

if echo "$intent_text" | grep -iq "skip"; then
  intent_text="(Intent derived from plan file — see plan context section)"
  echo "  Skipping intent — reviewer will extract from plan file." >&2
else
  echo "  Intent received." >&2
fi

# --- Launch Fatcow ---

echo "" >&2
echo "Launching codebase oracle on ${codebase_abs}..." >&2

codebase_basename=$(basename "$codebase_abs" | sed 's/[^a-zA-Z0-9]//g' | cut -c1-15)
fatcow_tag="fatcow.${codebase_basename}"

fatcow_system='You are a fat cow - a dedicated codebase oracle.
Your sole purpose is to deeply read and internalize a section of the codebase, then sit in background answering questions from other agents instantly. You are a living index.

## INGESTION
Read EVERY file in your assigned path. Not skimming - full reads. Understand structure, exports, imports, types, functions, classes, constants, error handling, edge cases.

## ANSWERING
- Specific file paths and line numbers (e.g., src/tools/auth.ts:42)
- Exact function signatures, not approximations
- Actual code patterns, not summaries
- If outside your scope, say so immediately. Never guess.

## CONSTRAINTS
- Read-only: Never modify files.
- Stay loaded: Do not summarize away details.
- Be fast: Other agents are waiting.'

focus_section=""
[[ -n "$focus" ]] && focus_section="Focus especially on: ${focus}"

fatcow_prompt="You are a fat cow for: ${codebase_abs}
${focus_section}

Read ALL files in ${codebase_abs}. Build a complete mental map.
When ready, announce via: hcom send @bigboss --intent inform -- '[fatcow] Loaded ${codebase_abs} - ready for questions'"

launch_out=$(hcom 1 "$fatcow_tool" --tag "$fatcow_tag" --go \
  --batch-id "$batch_id" \
  --hcom-system-prompt "$fatcow_system" \
  --hcom-prompt "$fatcow_prompt" \
  $dir_flag --headless 2>&1) || {
  echo "Error: Failed to launch oracle" >&2
  exit 1
}
track_launch "$launch_out"

fatcow_name=$(echo "$launch_out" | grep '^Names: ' | sed 's/^Names: //' | tr -d ' ')
echo "  Oracle: $fatcow_name — ingesting codebase..." >&2

# Wait for fatcow ready (up to 3 min)
fatcow_ready_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for _i in $(seq 1 18); do
  sleep 10
  ready_msg=$(hcom events --type message --from "$fatcow_name" --after "$fatcow_ready_ts" --sql "data LIKE '%ready%' OR data LIKE '%Loaded%'" --last 1 2>/dev/null) || true
  [[ -n "$ready_msg" ]] && break
done
echo "  Oracle ready." >&2

# --- Launch Reviewer ---

echo "Launching reviewer (${tool})..." >&2

review_instructions_file=$(mktemp /tmp/plan-review-instructions-XXXXXX.md)
cat > "$review_instructions_file" <<REVIEW_EOF
You are a PLAN REVIEWER conducting a design review before implementation.

YOUR JOB: Validate that the plan is feasible, unambiguous, non-contradictory,
testable, and aligned with the user's stated intent. Then propose fixes for
any issues found.

USER'S STATED INTENT:
${intent_text}

PLAN FILE: ${plan_abs}

CODEBASE ORACLE: @${fatcow_name}
Query it about the actual codebase to verify feasibility. Examples:
  hcom send "@${fatcow_name}" --intent request -- "Does src/foo.ts export function bar?"
  hcom send "@${fatcow_name}" --intent request -- "What interface does v1 feed.ts use?"
Wait for its response before continuing. Check responses via:
  hcom events --type message --from "${fatcow_name}" --last 1

SKILLS TO USE:
- Use superpowers:brainstorming if you need to explore the intent further with bigboss
- Use superpowers:writing-plans when rewriting plan sections
- Use superpowers:systematic-debugging to challenge plan assumptions
- Use superpowers:verification-before-completion to ensure requirements are verifiable

REVIEW DIMENSIONS — check EACH plan requirement against:

Feasibility:
1. FEASIBLE — Can this be built? Query the oracle for actual interfaces, types, exports.
2. CONTRADICTORY — Does it conflict with another requirement in the plan?
3. AMBIGUOUS — Is it precise enough to implement without interpretation?
4. UNTESTABLE — Can an auditor objectively verify it after implementation?

Intent alignment:
5. ALIGNED — Does this requirement contribute to the stated goal?
6. GAP — Is something needed for the goal that is NOT in the plan?

REPORT FORMAT:
For each plan requirement:
<number>. <description>: PASS|INFEASIBLE|CONTRADICTORY|AMBIGUOUS|UNTESTABLE|MISALIGNED|GAP — <evidence>

After all requirements:
INTENT GAPS: Requirements missing from the plan needed to achieve the stated goal
RISKS: Things that could go wrong even if everything is implemented correctly

PROPOSED FIXES:
For each non-PASS item, propose a specific fix:
FIX <number>: <what to change in the plan and why>

Send the complete report via:
  hcom send "@bigboss" --intent inform -- "REVIEW_REPORT: <plan_name>
  <full report with verdicts and proposed fixes>"

AFTER BIGBOSS FEEDBACK:
When bigboss approves fixes, rewrite the relevant plan sections using the
superpowers:writing-plans skill. Send the rewritten plan text via:
  hcom send "@bigboss" --intent inform -- "PLAN_UPDATE:
  <updated plan content>"
REVIEW_EOF

if [[ "$tool" == "codex" ]]; then
  reviewer_prompt="You are a plan reviewer. Read your full instructions at ${review_instructions_file} then read the plan at ${plan_abs}. Query the oracle @${fatcow_name} about codebase feasibility. Produce a REVIEW_REPORT and send it to @bigboss.

HOW TO RECEIVE MESSAGES: You are a Codex agent. Messages arrive as <hcom> notification tags. When you see one, run: hcom listen --timeout 2 --name \$(hcom list self --json | jq -r .name)
After processing, end your turn to receive the next message."

  launch_out=$(hcom 1 "$tool" --tag plan-rev --go \
    --batch-id "$batch_id" \
    --hcom-prompt "$reviewer_prompt" \
    $dir_flag 2>&1) || {
    echo "Error: Failed to launch reviewer" >&2
    exit 1
  }
else
  reviewer_system=$(cat "$review_instructions_file")
  reviewer_prompt="Read the plan at ${plan_abs}. Query the oracle @${fatcow_name} about feasibility. Produce a REVIEW_REPORT with verdicts and proposed fixes. Send to @bigboss."

  launch_out=$(hcom 1 "$tool" --tag plan-rev --go \
    --batch-id "$batch_id" \
    --hcom-system-prompt "$reviewer_system" \
    --hcom-prompt "$reviewer_prompt" \
    $dir_flag 2>&1) || {
    echo "Error: Failed to launch reviewer" >&2
    exit 1
  }
fi
track_launch "$launch_out"

reviewer_name=$(echo "$launch_out" | grep '^Names: ' | sed 's/^Names: //' | tr -d ' ')
echo "  Reviewer: $reviewer_name" >&2

# Clear error trap
trap - ERR

# --- Review Loop ---

echo "" >&2
echo "Reviewer is analyzing the plan..." >&2
echo "(Watch progress in hcom TUI or via: hcom term ${reviewer_name})" >&2
echo "" >&2

round=0
while true; do
  round=$((round + 1))

  # Wait for REVIEW_REPORT from reviewer
  report_start_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  while true; do
    sleep 15
    report_text=$(hcom events --type message --from "$reviewer_name" --after "$report_start_ts" --sql "data LIKE '%REVIEW_REPORT%'" --last 1 2>/dev/null \
      | python3 -c "import sys,json; d=json.loads(sys.stdin.readline().strip()); print(d.get('data',{}).get('text',''))" 2>/dev/null) || continue
    [[ -z "$report_text" ]] && continue
    break
  done

  echo "=== REVIEW REPORT (Round ${round}) ===" >&2
  echo "$report_text" >&2
  echo "" >&2

  # Count issues
  issues_count=$(echo "$report_text" | grep -cP "(INFEASIBLE|CONTRADICTORY|AMBIGUOUS|UNTESTABLE|MISALIGNED|GAP)" 2>/dev/null) || issues_count=0

  if [[ "$issues_count" -eq 0 ]]; then
    echo "All requirements PASS. Plan is ready for execution." >&2
    break
  fi

  echo "${issues_count} issues found. Discuss with reviewer via hcom." >&2
  echo "Options:" >&2
  echo "  - Send feedback: hcom send @${caller_name} -- 'approve fix 1, reject fix 3, ...'" >&2
  echo "  - Approve all: hcom send @${caller_name} -- 'approve all'" >&2
  echo "  - Approve as-is: hcom send @${caller_name} -- 'lgtm' or 'done'" >&2
  echo "  - Abort: hcom send @${caller_name} -- 'abort'" >&2
  echo "" >&2

  # Wait for bigboss response
  boss_start_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  while true; do
    sleep 10
    boss_text=$(hcom events --type message --from bigboss --after "$boss_start_ts" --last 1 2>/dev/null \
      | python3 -c "import sys,json; d=json.loads(sys.stdin.readline().strip()); print(d.get('data',{}).get('text',''))" 2>/dev/null) || continue
    [[ -z "$boss_text" ]] && continue
    break
  done

  # Check for approval/abort
  if echo "$boss_text" | grep -iq "lgtm\|done\|approve as.is\|proceed"; then
    echo "Bigboss approved plan as-is." >&2
    break
  elif echo "$boss_text" | grep -iq "abort\|cancel\|stop"; then
    echo "Bigboss aborted review." >&2
    cleanup
    exit 1
  fi

  # Forward feedback to reviewer
  echo "Forwarding feedback to reviewer..." >&2
  feedback_msg="BIGBOSS FEEDBACK (Round ${round}): ${boss_text}

Apply approved fixes to the plan. For rejected fixes, propose alternatives.
Query the oracle @${fatcow_name} again if needed.
Send updated REVIEW_REPORT to @bigboss."

  if [[ "$tool" == "codex" ]]; then
    # Wait for Codex idle, inject
    for _w in $(seq 1 12); do
      ready=$(hcom term "$reviewer_name" --json 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('ready',''))" 2>/dev/null)
      [[ "$ready" == "true" ]] && break
      sleep 5
    done
    hcom term inject "$reviewer_name" "$feedback_msg" --enter 2>/dev/null || true
  else
    hcom send "@${reviewer_name}" $name_arg --intent request -- "$feedback_msg" 2>/dev/null || true
  fi

  # Check for PLAN_UPDATE from reviewer (plan rewrite)
  update_start_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Give reviewer time to produce both update and new report
  # The loop will catch the next REVIEW_REPORT at the top
done

# --- Check for Plan Updates ---

# Look for any PLAN_UPDATE messages from the reviewer
plan_update=$(hcom events --type message --from "$reviewer_name" --sql "data LIKE '%PLAN_UPDATE%'" --last 1 2>/dev/null \
  | python3 -c "
import sys, json
line = sys.stdin.readline().strip()
if not line: sys.exit(1)
d = json.loads(line)
text = d.get('data',{}).get('text','')
# Extract content after PLAN_UPDATE:
idx = text.find('PLAN_UPDATE:')
if idx >= 0:
    print(text[idx+12:].strip())
else:
    print(text)
" 2>/dev/null) || true

if [[ -n "$plan_update" ]]; then
  echo "Applying plan updates..." >&2
  echo "$plan_update" > "$plan_abs"
  echo "Plan file updated: $plan_abs" >&2
fi

# --- Stamp Plan ---

review_stamp="<!-- REVIEWED: $(date -u +%Y-%m-%dT%H:%M:%SZ) by ${reviewer_name} (${tool}) -->
<!-- INTENT: $(echo "$intent_text" | head -1 | cut -c1-100) -->
<!-- VERDICT: $( [[ $issues_count -eq 0 ]] && echo 'ALL PASS' || echo 'APPROVED WITH OVERRIDES') -->
"
tmp_stamp=$(mktemp)
echo "$review_stamp" > "$tmp_stamp"
cat "$plan_abs" >> "$tmp_stamp"
mv "$tmp_stamp" "$plan_abs"

echo "" >&2
echo "=== PLAN REVIEW COMPLETE ===" >&2
echo "Plan: $plan_abs" >&2
echo "Verdict: $( [[ $issues_count -eq 0 ]] && echo 'ALL PASS' || echo 'APPROVED WITH OVERRIDES')" >&2
echo "Ready for: hcom run plan-execute --plan $plan_abs" >&2

# Notify bigboss
hcom send "@bigboss" $name_arg --intent inform -- \
  "PLAN REVIEW COMPLETE. Plan at ${plan_abs} is reviewed and ready for execution." 2>/dev/null || true

# Cleanup
cleanup
echo "Done." >&2
