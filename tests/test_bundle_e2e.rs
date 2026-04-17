//! End-to-end coverage for `hcom bundle prepare` and `hcom bundle cat`
//! transcript resolution. Exercises the four-tier fallback chain added by
//! `fix/bundle-prepare-derive-transcript`:
//!
//!     instances row → stopped-life snapshot → derive from session_id →
//!     bundle `refs.files`
//!
//! Each test spins up an isolated `HCOM_DIR` and `CLAUDE_CONFIG_DIR` tempdir
//! and invokes the dev binary (`env!("CARGO_BIN_EXE_hcom")`). The user's
//! real hcom state is never touched.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use rusqlite::params;

const HCOM_BIN: &str = env!("CARGO_BIN_EXE_hcom");

/// Invoke `hcom` with `HCOM_DIR`/`CLAUDE_CONFIG_DIR`/`HOME` pinned at
/// per-test tempdirs and capture stdout + stderr.
fn hcom(hcom_dir: &Path, claude_dir: &Path, args: &[&str]) -> Output {
    let mut cmd = Command::new(HCOM_BIN);
    cmd.args(args)
        .env("HCOM_DIR", hcom_dir)
        .env("CLAUDE_CONFIG_DIR", claude_dir)
        // Isolate any fallback that reads HOME (dirs::home_dir, tilde
        // expansion) from the real user home.
        .env("HOME", hcom_dir);
    cmd.output()
        .unwrap_or_else(|e| panic!("failed to spawn hcom {args:?}: {e}"))
}

fn expect_ok(out: &Output, label: &str) {
    assert!(
        out.status.success(),
        "{label} failed (status {:?})\nstdout:\n{}\nstderr:\n{}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
}

/// Force DB creation + schema by running any command that opens the DB.
fn init_hcom_dir(hcom_dir: &Path, claude_dir: &Path) {
    let out = hcom(hcom_dir, claude_dir, &["list", "--json"]);
    expect_ok(&out, "init (hcom list --json)");
}

fn db_path(hcom_dir: &Path) -> PathBuf {
    hcom_dir.join("hcom.db")
}

fn open_db(hcom_dir: &Path) -> rusqlite::Connection {
    rusqlite::Connection::open(db_path(hcom_dir)).expect("open hcom.db")
}

/// Write a minimal two-message Claude JSONL transcript under
/// `<claude_dir>/projects/<project>/<sid>.jsonl`. Text arguments become the
/// user and assistant messages so tests can look for distinctive markers in
/// the rendered output.
fn seed_claude_transcript(
    claude_dir: &Path,
    project: &str,
    sid: &str,
    user_text: &str,
    assistant_text: &str,
) -> PathBuf {
    let project_dir = claude_dir.join("projects").join(project);
    std::fs::create_dir_all(&project_dir).unwrap();
    let path = project_dir.join(format!("{sid}.jsonl"));
    let lines = [
        serde_json::json!({
            "type": "user",
            "timestamp": "2026-04-13T12:00:00Z",
            "message": {
                "content": [{"type": "text", "text": user_text}]
            }
        }),
        serde_json::json!({
            "type": "assistant",
            "timestamp": "2026-04-13T12:00:01Z",
            "message": {
                "content": [{"type": "text", "text": assistant_text}]
            }
        }),
    ];
    std::fs::write(
        &path,
        lines
            .iter()
            .map(serde_json::Value::to_string)
            .collect::<Vec<_>>()
            .join("\n"),
    )
    .unwrap();
    path
}

fn seed_instance(
    db: &rusqlite::Connection,
    name: &str,
    tool: &str,
    session_id: Option<&str>,
    transcript_path: &str,
) {
    db.execute(
        "INSERT INTO instances (name, tool, session_id, transcript_path, status, created_at)
         VALUES (?, ?, ?, ?, 'inactive', ?)",
        params![name, tool, session_id, transcript_path, 1_000_000.0f64],
    )
    .unwrap();
}

fn seed_stopped_event(db: &rusqlite::Connection, instance: &str, snapshot: serde_json::Value) {
    let data = serde_json::json!({
        "action": "stopped",
        "by": "cli",
        "reason": "killed",
        "snapshot": snapshot,
    });
    db.execute(
        "INSERT INTO events (timestamp, type, instance, data)
         VALUES (?, 'life', ?, ?)",
        params!["2026-04-13T12:00:02Z", instance, data.to_string()],
    )
    .unwrap();
}

/// Seed a bundle event and return its numeric event ID (usable as the
/// argument to `hcom bundle cat <id>`).
fn seed_bundle_event(
    db: &rusqlite::Connection,
    bundle_id: &str,
    created_by: &str,
    refs: serde_json::Value,
) -> i64 {
    // `get_bundle_by_id` stores and looks up ids with a `bundle:` prefix.
    let prefixed = if bundle_id.starts_with("bundle:") {
        bundle_id.to_string()
    } else {
        format!("bundle:{bundle_id}")
    };
    let data = serde_json::json!({
        "bundle_id": prefixed,
        "title": format!("e2e bundle {bundle_id}"),
        "description": "e2e test",
        "created_by": created_by,
        "refs": refs,
    });
    db.execute(
        "INSERT INTO events (timestamp, type, instance, data)
         VALUES (?, 'bundle', ?, ?)",
        params!["2026-04-13T12:00:03Z", created_by, data.to_string()],
    )
    .unwrap();
    db.last_insert_rowid()
}

fn prepare_json(hcom_dir: &Path, claude_dir: &Path, agent: &str) -> serde_json::Value {
    let out = hcom(
        hcom_dir,
        claude_dir,
        &["bundle", "prepare", "--for", agent, "--json"],
    );
    expect_ok(&out, &format!("bundle prepare --for {agent}"));
    serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "bundle prepare --json didn't return JSON: {e}\nstdout:\n{}",
            String::from_utf8_lossy(&out.stdout)
        )
    })
}

// ─── Scenarios ──────────────────────────────────────────────────────────

/// Tier 1 — the happy path. Instance row is live, transcript file is live.
/// Just a smoke test that nothing downstream broke.
#[test]
fn prepare_happy_path_live_instance() {
    let hcom_dir = tempfile::tempdir().unwrap();
    let claude_dir = tempfile::tempdir().unwrap();
    init_hcom_dir(hcom_dir.path(), claude_dir.path());

    let sid = "aaaa1111-2222-3333-4444-aaaaaaaaaaaa";
    let tpath = seed_claude_transcript(
        claude_dir.path(),
        "projA",
        sid,
        "live ping",
        "LIVE-MARKER-PONG",
    );

    let db = open_db(hcom_dir.path());
    seed_instance(&db, "alpha", "claude", Some(sid), tpath.to_str().unwrap());
    drop(db);

    let result = prepare_json(hcom_dir.path(), claude_dir.path(), "alpha");
    let text = result["transcript"]["text"].as_str().unwrap_or("");
    assert!(
        text.contains("LIVE-MARKER-PONG"),
        "expected assistant marker in rendered transcript; got:\n{text}"
    );
}

/// Tier 2 — instance row is gone but a `stopped` life-event snapshot carries
/// a live `transcript_path`. This was the existing (upstream) fix; re-testing
/// it end-to-end protects against regressions in the tiered resolver.
#[test]
fn prepare_falls_back_to_stopped_snapshot_path() {
    let hcom_dir = tempfile::tempdir().unwrap();
    let claude_dir = tempfile::tempdir().unwrap();
    init_hcom_dir(hcom_dir.path(), claude_dir.path());

    let sid = "bbbb2222-3333-4444-5555-bbbbbbbbbbbb";
    let tpath = seed_claude_transcript(
        claude_dir.path(),
        "projB",
        sid,
        "stopped ping",
        "SNAPSHOT-PATH-MARKER",
    );

    let db = open_db(hcom_dir.path());
    seed_stopped_event(
        &db,
        "beta",
        serde_json::json!({
            "name": "beta",
            "tool": "claude",
            "session_id": sid,
            "transcript_path": tpath.to_string_lossy(),
        }),
    );
    drop(db);

    let result = prepare_json(hcom_dir.path(), claude_dir.path(), "beta");
    let text = result["transcript"]["text"].as_str().unwrap_or("");
    assert!(
        text.contains("SNAPSHOT-PATH-MARKER"),
        "expected snapshot-path transcript rendered; got:\n{text}"
    );
}

/// Tier 3 — stopped snapshot carries only `session_id`. The path must be
/// derived via `<CLAUDE_CONFIG_DIR>/projects/**/<sid>.jsonl`. This is the
/// primary new fallback from commit `f71512a`.
#[test]
fn prepare_derives_path_from_snapshot_session_id() {
    let hcom_dir = tempfile::tempdir().unwrap();
    let claude_dir = tempfile::tempdir().unwrap();
    init_hcom_dir(hcom_dir.path(), claude_dir.path());

    let sid = "cccc3333-4444-5555-6666-cccccccccccc";
    let _tpath = seed_claude_transcript(
        claude_dir.path(),
        "projC",
        sid,
        "derived ping",
        "DERIVED-FROM-SID-MARKER",
    );

    let db = open_db(hcom_dir.path());
    // snapshot intentionally omits `transcript_path`.
    seed_stopped_event(
        &db,
        "gamma",
        serde_json::json!({
            "name": "gamma",
            "tool": "claude",
            "session_id": sid,
        }),
    );
    drop(db);

    let result = prepare_json(hcom_dir.path(), claude_dir.path(), "gamma");
    let text = result["transcript"]["text"].as_str().unwrap_or("");
    assert!(
        text.contains("DERIVED-FROM-SID-MARKER"),
        "expected transcript derived from session_id; got:\n{text}"
    );
}

/// Instance row exists, but its stored `transcript_path` is stale (file has
/// been deleted). The fix must detect the stale path and re-derive from
/// `session_id`. Before the fix, the `!p.is_empty()` guard returned the dead
/// path verbatim and the transcript rendered empty.
#[test]
fn prepare_with_stale_instance_path_derives_from_session_id() {
    let hcom_dir = tempfile::tempdir().unwrap();
    let claude_dir = tempfile::tempdir().unwrap();
    init_hcom_dir(hcom_dir.path(), claude_dir.path());

    let sid = "dddd4444-5555-6666-7777-dddddddddddd";
    let _fresh = seed_claude_transcript(
        claude_dir.path(),
        "projD",
        sid,
        "stale-row ping",
        "STALE-ROW-MARKER",
    );

    let db = open_db(hcom_dir.path());
    seed_instance(
        &db,
        "delta",
        "claude",
        Some(sid),
        "/nonexistent/deleted-long-ago.jsonl",
    );
    drop(db);

    let result = prepare_json(hcom_dir.path(), claude_dir.path(), "delta");
    let text = result["transcript"]["text"].as_str().unwrap_or("");
    assert!(
        text.contains("STALE-ROW-MARKER"),
        "expected stale-path to trigger session_id derivation; got:\n{text}"
    );
}

/// Snapshot with a `NULL`/absent `tool` field must not abort the SQL row
/// binding. Before the fix, `row.get::<_, String>` on a NULL column returned
/// `Err` and the whole stopped-event branch short-circuited — so even a
/// valid session_id never got used.
#[test]
fn prepare_tolerates_null_tool_in_snapshot() {
    let hcom_dir = tempfile::tempdir().unwrap();
    let claude_dir = tempfile::tempdir().unwrap();
    init_hcom_dir(hcom_dir.path(), claude_dir.path());

    let sid = "eeee5555-6666-7777-8888-eeeeeeeeeeee";
    let _tpath = seed_claude_transcript(
        claude_dir.path(),
        "projE",
        sid,
        "null-tool ping",
        "NULL-TOOL-MARKER",
    );

    let db = open_db(hcom_dir.path());
    // snapshot intentionally omits both tool and transcript_path.
    seed_stopped_event(
        &db,
        "epsilon",
        serde_json::json!({
            "name": "epsilon",
            "session_id": sid,
        }),
    );
    drop(db);

    let result = prepare_json(hcom_dir.path(), claude_dir.path(), "epsilon");
    let text = result["transcript"]["text"].as_str().unwrap_or("");
    assert!(
        text.contains("NULL-TOOL-MARKER"),
        "NULL tool should default to claude and derive from sid; got:\n{text}"
    );
}

/// Tier 4 — `hcom bundle cat` when the producing agent has been completely
/// pruned (no instance row, no stopped event). The bundle's own `refs.files`
/// carries the transcript path, so the cat command should still render the
/// transcript section. New fallback from commit `bb6fa75`.
#[test]
fn cat_falls_back_to_refs_files_when_producer_is_gone() {
    let hcom_dir = tempfile::tempdir().unwrap();
    let claude_dir = tempfile::tempdir().unwrap();
    init_hcom_dir(hcom_dir.path(), claude_dir.path());

    let sid = "ffff6666-7777-8888-9999-ffffffffffff";
    let tpath = seed_claude_transcript(
        claude_dir.path(),
        "projF",
        sid,
        "refs-files ping",
        "REFS-FILES-MARKER",
    );

    let db = open_db(hcom_dir.path());
    let event_id = seed_bundle_event(
        &db,
        "abc",
        "ghost-agent",
        serde_json::json!({
            "files": [tpath.to_string_lossy()],
            "events": [],
            "transcript": [{"range": "1-1", "detail": "normal"}],
        }),
    );
    drop(db);

    let id_arg = event_id.to_string();
    let out = hcom(
        hcom_dir.path(),
        claude_dir.path(),
        &["bundle", "cat", &id_arg],
    );
    expect_ok(&out, "bundle cat (refs.files fallback)");
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("REFS-FILES-MARKER"),
        "expected refs.files fallback to render transcript; got:\n{stdout}"
    );
}
