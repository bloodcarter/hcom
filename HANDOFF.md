# hcom Contribution Handoff

This document captures the full context of work done on the hcom project so a new Claude session can pick up where we left off.

## Repositories

- **hcom fork**: `~/repos/hcom` — fork of [aannoo/hcom](https://github.com/aannoo/hcom), remote `fork` → `bloodcarter/hcom`
- **swarm-skills**: `~/repos/swarm-skills` — [bloodcarter/swarm-skills](https://github.com/bloodcarter/swarm-skills) (private), Claude Code skills for multi-agent collaboration via hcom
- **Installed binary**: `~/.local/bin/hcom` — rebuilt from our fork with the stale blocked fix applied
- **Installed skills**: `~/.claude/skills/hcom-multi-agent/`, `hcom-worker/`, `hcom-screen-interaction/`

## Architecture Understanding

### How hcom agents work

- `hcom N claude` spawns agents wrapped in a **PTY wrapper** (`delivery.rs` runs a background delivery loop)
- PTY agents get **physical message delivery** — messages are injected into the terminal automatically, no hooks needed
- The Stop hook's blocking `poll_messages()` path is **only for non-PTY agents** (vanilla `claude` + `hcom start`)
- PTY agents hit `if ctx.is_pty_mode` in `handle_stop()` and return immediately (line 1075 of `claude.rs`)

### Key implication

If you're launched via `hcom 1 claude`, you're a PTY agent. You get physical delivery. The Stop hook freeze bug doesn't affect you. The only bug that affects PTY agents is the stale blocked status (below).

## Bug Fix: Stale Blocked Status (READY TO PR)

### Branch: `fix/stop-hook-nonblocking` (1 commit on top of upstream `main`)

```
3a95f64 fix: clear stale blocked status when approval prompt disappears
```

### The bug

When a PTY-detected approval prompt is resolved (user approves a permission), the agent's status stays `■ blocked` in `hcom list` even though it moved on to active work.

### Root cause: `src/delivery.rs` ~line 922

The delivery loop's recovery branch checks `if status == ST_ACTIVE` but after an approval prompt, status is `ST_BLOCKED`. So recovery is skipped and the DB stays blocked until a hook eventually clears it.

### The fix: `src/delivery.rs` ~line 917

Added an immediate check: when `approval_showing` goes false but DB still says `"blocked"`, clear it to `"listening"` right away. This runs before the existing `ST_ACTIVE` stability recovery.

```rust
} else if gate.reason == "not_idle" {
    // Immediate recovery: if approval just cleared but DB still says blocked,
    // clear it now — no need to wait for stability timeout.
    match db.get_status(&current_name) {
        Ok(Some((status, _))) if status == "blocked" => {
            if let Err(e) = db.set_status(
                &current_name,
                "listening",
                "pty:approval_cleared",
            ) { ... }
            attempt = 0;
            continue;
        }
        _ => {}
    }
    // ... existing ST_ACTIVE stability recovery follows
```

### Verification done

- Subagent independently verified all claims from the initial bug report by reading the source
- Spawned test agent, triggered permission prompts, confirmed status clears within 2 seconds
- Affects all agent types (Claude, Gemini, Codex) since it's in the shared PTY delivery loop

### What's needed

1. Force-push the branch to fork (it was rebased — old Stop hook commit removed)
2. Open a new PR (NOT #5, that was closed) with just this fix
3. Include the verification details in the PR description

## Closed PR #5 (Stop Hook Non-Blocking)

PR [aannoo/hcom#5](https://github.com/aannoo/hcom/pull/5) was closed with an explanation. Summary:

- We initially thought the Stop hook's blocking `poll_messages()` was a bug causing Claude Code to freeze
- It IS a real freeze for non-PTY agents, but PTY agents (the main use case) never hit that code path
- The blocking is intentional for non-PTY — it's their message delivery mechanism
- Our fix made the Stop hook non-blocking but left non-PTY agents deaf when idle
- We decided the tradeoff wasn't worth it and closed the PR

## Skills Project (swarm-skills)

Three Claude Code skills for multi-agent collaboration:

1. **hcom-multi-agent** — orchestrator skill: spawn workers, assign tasks, monitor, unblock, collect results
2. **hcom-worker** — worker skill: task lifecycle, peer-to-peer, review loops, human intervention
3. **hcom-screen-interaction** — detect and resolve interactive prompts blocking agents

### Key findings from testing

- **Orchestrator must actively monitor** (`hcom list` every 15-30s), not passively wait for notifications
- **Orchestrator's own permission prompts** pause everything — tell the human upfront, delegate build/test to workers
- **Worker environment differences** — tmux panes may not have the same PATH
- **AskUserQuestion "Type something"** — do NOT press Enter first (cancels the dialog). Type directly, then Enter.
- **Skills defer to repo conventions** — they only cover hcom communication mechanics, not how to plan/review/code

### Failure modes identified and fixed in skills

1. Orchestrator goes passive (waits instead of polling) → enforced active monitoring loop
2. Permission prompt interruptions → strengthened warning + delegation advice
3. PATH differences in worker tmux panes → added environment note

## Feature: Resume by Session ID and Codex Thread Name

### Branch: `dev` (on top of upstream v0.7.4)

Two features in `src/commands/resume.rs`:

1. **Session-ID resume**: `hcom r <uuid>` finds the transcript on disk (Claude/Codex/Gemini), extracts last CWD, and launches with full hcom wrapping.
2. **Codex thread name resolution**: `hcom r stabilization-review` looks up `~/.codex/session_index.jsonl` for the thread name → UUID mapping, then delegates to session-ID resume.

Also made `claude_config_dir()` and `detect_agent_type()` `pub(crate)` in `transcript.rs`.

### Git state

- Branch: `dev`, pushed to `fork/dev`
- 2 commits on top of upstream v0.7.4

## Known hcom Tool Bugs (from P0+P1 experiment)

Observed during a live multi-agent orchestration experiment (documented in `dasha-code/.worktrees/p1-controller-streaming/docs/reviews/2026-03-09-hcom-p0-p1-parallel-experiment-log.md`).

### 1. `hcom term` / inject port unreliable

- `hcom term <agent>` returns "No inject port for '<agent>'. Instance not running or not PTY-managed." even when the agent was launched with `--terminal tmux` and shows as PTY-managed.
- This means the supervisor cannot read or unblock the agent's screen — permanent deadlock if the agent hits an approval prompt.
- Happens intermittently; not yet root-caused.

### 2. `hcom transcript` null for PTY-managed Codex instances

- `hcom transcript <name>` shows `transcript_path: null` for Codex agents launched via `hcom 1 codex`.
- Workaround: use `hcom term` (screen dump) or `hcom events --last N`.

### 3. Codex PTY delivery is notification-only

- For Claude: injects bare `<hcom>`, Claude's Stop hook delivers the full message body.
- For Codex/Gemini: injects `<hcom>[preview]</hcom>` with just the envelope (sender, intent), deliberately truncated to ~60 chars. Message body is NOT included.
- Codex agents must run `hcom listen` to retrieve message content. This is by design (input box width constraint), not a bug per se.

### 4. "blocked" vs "listening with uncommitted text" not distinguished

- Both states require supervisor attention but look different in `hcom list`.
- No single command to show all agents needing attention.

## Skills Updates (current state)

Skills are installed in three locations:
- `~/.claude/skills/` — for Claude agents
- `~/.codex/skills/` — for Codex agents
- `~/repos/swarm-skills/` — source repo (pushed to GitHub)

Plus the dual-reviewer-gate skill in `~/.codex/superpowers/skills/dual-reviewer-gate/`.

Key additions since initial skills:
- PTY message delivery explanation (worker)
- Reqwatch deadlock prevention (both)
- `hcom term inject` misuse warning (orchestrator)
- Scaling guidance: max ~2 workers (orchestrator)
- PTY inject port smoke test after spawn (orchestrator)
- Backtick quoting in messages (both)
- Event-driven supervision protocol (orchestrator)
- Cross-PR file ownership rule (orchestrator)
- Reviewer session safety (dual-reviewer-gate)

## What's Next

1. **Stale blocked fix PR**: force-push `fix/stop-hook-nonblocking` and open PR on `aannoo/hcom`
2. **Session-ID resume PR**: consider upstreaming the `dev` branch features
3. **Investigate inject port bug**: root-cause the intermittent "No inject port" for PTY-managed agents
4. **Investigate transcript null**: why PTY-managed Codex instances have null transcript paths
