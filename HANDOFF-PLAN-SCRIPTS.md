# Handoff: plan-review & plan-execute Scripts

**Date**: 2026-03-19
**Author**: guru (Claude Opus 4.6)
**Status**: plan-review working, plan-execute needs fixes, both need polish

---

## What Was Built

Two new `hcom run` workflow scripts for autonomous plan execution with independent auditing:

### `hcom run plan-review --plan <path> --codebase <path> [--intent "text"]`

Reviews an implementation plan BEFORE execution. Catches contradictions, ambiguity, infeasibility, and intent misalignment.

**Agents**: fatcow (Claude, headless codebase oracle) + reviewer (Codex by default)

**Flow**:
1. Launches fatcow on codebase, waits for ready
2. Launches reviewer with instructions written to temp file (Codex can't handle long CLI prompts)
3. Reviewer reads plan, queries fatcow about codebase reality, produces REVIEW_REPORT
4. Report has per-requirement verdicts: PASS/INFEASIBLE/CONTRADICTORY/AMBIGUOUS/UNTESTABLE/MISALIGNED/GAP
5. Reviewer proposes specific fixes for each issue
6. Bigboss approves/rejects fixes
7. Reviewer rewrites plan with approved changes

**Skills the reviewer should use**: superpowers:brainstorming (intent discovery), superpowers:writing-plans (plan rewrite), superpowers:systematic-debugging (challenge assumptions), superpowers:verification-before-completion (verifiable criteria)

### `hcom run plan-execute --plan <path> [--audit-tool codex] [--start-phase N] [--max-retries N]`

Executes an approved plan phase-by-phase with independent compliance auditing.

**Agents**: implementer (Claude) + auditor (Codex by default)

**Flow**:
1. Extracts phases from plan (regex: `### Phase N: Title`)
2. For each phase: assign to implementer → wait for PHASE_DONE → trigger auditor → wait for AUDIT_RESULT
3. VERDICT: PASS → next phase. VERDICT: FAIL → implementer fixes, retry (max 3)
4. Max retries → escalate to bigboss (override/retry/abort)

**Key design**: The script controls the gate — neither agent can subvert the workflow. The auditor reads the plan directly, not through the implementer's framing.

---

## Files

| File | Purpose |
|------|---------|
| `src/scripts/bundled/plan-review.sh` | The plan-review script (~250 lines) |
| `src/scripts/bundled/plan-execute.sh` | The plan-execute script (~350 lines) |
| `src/scripts.rs` | Script registration (add both to SCRIPTS array) |
| `src/commands/run.rs` | Test assertion needs updating (count = 5, add both names) |

---

## How Communication Works

### Controller → Agents
- **Claude agents**: `hcom send @<name> --from <caller> --intent request -- "message"`
- **Codex agents**: `hcom term inject <name> "message text" --enter` (wait for `ready=true` first)
  - Codex PTY delivery is notification-only — `hcom send` delivers truncated preview, not full body
  - `term inject` types directly into the Codex terminal prompt

### Agents → Controller
- Agents send messages containing keywords (PHASE_DONE, AUDIT_RESULT, REVIEW_REPORT)
- Controller polls `hcom events --type message --from <agent> --after <timestamp> --sql "data LIKE '%KEYWORD%'" --last 1` every 15 seconds

### Controller Identity
- Uses `--from <name>` on sends (external sender mode, no registered identity needed)
- NO `hcom start` — ad-hoc identities get stale-cleaned within seconds
- NO `hcom listen` — doesn't work for unregistered identities
- Events polling works without any identity

---

## Known Issues (Current State)

### Critical

1. **Codex auditor sometimes misses messages**
   - Codex delivery is notification-only (`<hcom>` preview tag, ~60 chars)
   - When Codex is idle, the notification tag may not trigger a new turn
   - Workaround: `hcom term inject` to type audit request directly into prompt
   - Root cause: hcom's Codex delivery design (intentional, not a bug — input box width constraint)

2. **`hcom events --wait` only matches FUTURE events**
   - Messages arriving between `hcom send` and `events --wait` are missed
   - Workaround: timestamp-based polling with `--after` instead of `--wait`
   - This is why both scripts use polling loops, not event subscriptions

3. **Ad-hoc identities get stale-cleaned instantly**
   - `hcom start --as X` creates identity bound to the calling process
   - When that process exits (the `hcom` CLI), identity is marked inactive
   - `HEARTBEAT_THRESHOLD_NO_TCP = 10 seconds` kills it
   - This is why scripts use `--from` instead of `--name` for sends
   - PR #14 was submitted and closed — the root cause is hooks lifecycle, not stale checker

### Annoying

4. **TUI noise from `prev` identity**
   - Old keepalive loops and collision subscriptions from previous runs keep recreating `prev`
   - Fix: `hcom reset --go` clears everything, but also kills all agents
   - Fix: `hcom events unsub <id>` to remove stale subscriptions manually

5. **Stale agents accumulate**
   - Each failed run leaves orphaned agents (fatcow, reviewer, implementer, auditor)
   - Must `hcom kill all` periodically to clean up
   - The scripts have cleanup traps but they don't always fire (SIGKILL, script crashes)

6. **`hcom send` to non-existent `--from` name works but can't receive replies**
   - `--from plan-review` sends fine, but nobody can send back to `@plan-review`
   - The script doesn't need replies — it polls events. But the user instructions say "send to @plan-review" which fails.
   - The user must send to `@bigboss` instead (their own identity)

### Architectural

7. **Cross-model auditing works but auditor rationalizes**
   - Claude auditor: gives "PASS (with caveats)" — rationalizes deviations
   - Codex auditor: catches real issues Claude misses (traced actual Electron app path, found voice not wired)
   - But even Codex eventually rationalized Phase 4 E2E as PASS when HeadlessVcRuntime was used instead of real Electron
   - The `^VERDICT: PASS$` grep rejects qualified passes, forcing binary PASS/FAIL

8. **Plan quality determines execution success**
   - If plan says "copy verbatim" but v2 needs different interfaces → auditor correctly FAILs → implementer can't fix → max retries → escalation
   - plan-review exists to catch these BEFORE execution
   - But plan-review's reviewer also has convenience bias — proposes fixes that are easier, not necessarily what the user wants

---

## User Feedback (Bigboss)

### Direct quotes and what they mean

1. **"Are you a fucking idiot? You're suggesting to hard code specific requirements for a specific project into an hcom built-in command."**
   - Context: I suggested adding project-specific audit checks (like "check for HeadlessVcRuntime") to the auditor prompt
   - Lesson: The scripts must be GENERIC. No project-specific knowledge baked in.

2. **"You're just doing band-aiding"**
   - Context: I was patching hcom script issues one by one instead of investigating root causes
   - Lesson: Launch sub-agents to investigate properly before patching. Understand the system.

3. **"Can you please stop going in circles"**
   - Context: Cycling between listen/poll/subscribe approaches without understanding why each fails
   - Lesson: Test assumptions with minimal repros BEFORE implementing.

4. **"The plan review command is just like a compiler — it doesn't tell you whether the program will do what you want"**
   - Context: I designed plan-review as a feasibility checker only
   - Lesson: Plan-review must also check INTENT ALIGNMENT — does the plan actually solve the stated problem?

5. **"We should use superpowers brainstorm skill for understanding bigboss intent"**
   - Lesson: Leverage existing skills (brainstorming, writing-plans) instead of building everything from scratch.

6. **"If I tell you an analogy... 90% of the work is the plan review"**
   - Context: I proposed making plan-review part of plan-execute
   - Lesson: plan-review is a separate, interactive, bigboss-heavy command. plan-execute is fire-and-forget.

7. **"Why would we fight with hcom in the way it works?"**
   - Context: I was trying to make ad-hoc identities persist by patching hcom internals
   - Lesson: Work WITH the tool's design. If ad-hoc dies, don't use ad-hoc. Find the pattern that works (--from).

---

## What Works Well

1. **`--from` for sends** — no identity registration, no stale cleanup, no noise
2. **Timestamp-based events polling** — reliable, no race conditions
3. **`hcom term inject` for Codex** — wait for `ready=true`, inject full text + enter
4. **Phase extraction regex** — handles `##`, `###`, `####`, strips `(N days)` suffix
5. **Binary PASS/FAIL verdicts** — `grep -qP "^VERDICT: PASS\s*$"` rejects qualified passes
6. **Codex as auditor** — different model family catches different issues than Claude
7. **Fatcow integration** — reviewer queries codebase oracle for file:line evidence
8. **`--intent` CLI flag** — no hcom messaging needed for intent, just a string

---

## What Needs Fixing Next

1. **plan-execute bigboss escalation** — uses `events --from bigboss` but bigboss may not have an identity. Should accept from any sender or use `--from` pattern.

2. **plan-execute needs `--from` refactor** — still has some `--name` references from old versions. Needs same `--from` treatment as plan-review.

3. **Auditor prompt for plan-execute** — needs the stronger "check SUBSTANCE" prompt. Current version may still have the weaker prompt on some code paths.

4. **plan-review bigboss feedback loop** — the `send @plan-review` instruction in the output is wrong (plan-review is a --from name, not an agent). Should tell user to send to `@bigboss`.

5. **Test the full pipeline** — plan-review → approve → plan-execute → all phases pass audit. Never been tested end-to-end in one session.

6. **Skills integration** — the reviewer agent is told to use superpowers skills but Codex may not have them installed. Verify Codex skill paths.

7. **Cleanup on script exit** — `trap cleanup EXIT` works for normal exit but orphans agents on SIGKILL. Consider a watchdog or periodic cleanup.

---

## Architecture Decisions

### Why two commands, not one?
Plan-review is interactive (bigboss participates). Plan-execute is autonomous (bigboss walks away). Mixing them defeats the fire-and-forget purpose of execute.

### Why cross-model auditing?
Claude auditing Claude has same-family convenience bias. Codex (GPT-5.4) catches things Claude rationalizes away. Proven: Codex found voice pipeline not wired end-to-end, Claude gave PASS three times.

### Why `--from` instead of `--name`?
Ad-hoc identities created by `hcom start --as X` die within seconds due to hcom's heartbeat mechanism (10s timeout for non-PTY instances). `--from` creates an external sender — no registration, no heartbeat, no stale cleanup.

### Why events polling instead of hcom listen?
`hcom listen` doesn't work for unregistered identities (returns empty immediately). `events --wait` only matches future events (misses already-arrived messages). Timestamp-based polling with `--after` is the only reliable pattern.

### Why term inject for Codex?
Codex PTY delivery injects truncated `<hcom>` preview tags (~60 chars). The agent may not process these when idle. `term inject` types the full request directly into the prompt — guaranteed delivery if agent is at idle prompt (`ready=true`).
