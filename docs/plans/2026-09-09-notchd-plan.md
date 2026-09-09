# Notchd: a flight recorder and undo button for every AI agent on the Mac

Written 2026-09-09. Built for a while under the working title "Rewind";
the product is Notchd.

This is not an iteration of the usage meter that lived in this repository
before it. That app read quota from vendor endpoints and drew it, and every
idea in its last plan (pace marks, burn rate, cache health, context pressure)
was still a meter. This document starts from a different question and ends in
a different product, with a different surface, different data, and a
different user.

| | The usage meter | Notchd |
|---|---|---|
| Question it answers | How much quota do I have left? | What did agents change on my machine, and can I take it back? |
| Data | Vendor usage endpoints, OAuth tokens | Local hooks, transcripts, and the filesystem itself |
| Behaviour | Passive. Reads and displays | Active. Snapshots before, restores after |
| Surface | A glass notch of dials | A timeline window, a menu bar status, and a system-wide undo |
| Network | Talks to every vendor | Never talks to anyone |
| User | Someone watching a budget | Someone who runs agents on their real machine, and developers building agents |

Nothing in the Providers directory survives. What survives is the app shell,
the updater, the process liveness code, and the honesty invariant.

## 1. The problem

People run coding agents on the host, not in a sandbox, because that is where
the editor, the credentials, and the running dev server are. The agent then
does three kinds of things:

1. Edits files through its own edit tool. The vendor usually checkpoints these.
   Claude Code has `/rewind`. OpenCode keeps a shadow git repo under
   `~/.local/share/opencode/snapshot`. Cursor has checkpoints.
2. Runs shell commands that change the filesystem. `git reset --hard`,
   `rm -rf build`, a migration, a `sed -i` over a directory, a global
   `npm install`. No vendor checkpoints these. This is where the horror stories
   come from.
3. Changes things outside the project. `~/.zshrc`, `~/.config`, another repo,
   the Keychain, a database.

Each vendor covers only kind 1, only for its own edits, only inside its own
session, and only while that session is open. Nothing covers the machine. When
three agents from two vendors work in the same afternoon, there is no single
answer to "what changed today, who did it, and undo it".

## 2. The product

**One sentence.** Every file an agent touched and every command an agent ran,
across Claude Code, Codex, Gemini CLI, OpenCode, and Cursor, recorded in one
timeline you can scrub, diff, and revert, even after the terminal is closed.

**For users who run agents.** A menu bar item that reads "3 agents active, 41
files changed in the last hour" and a window where a change can be selected
and undone. Confidence to let agents run with fewer permission prompts because
the safety net is outside the agent.

**For developers building agents.** An open, tiny hook protocol. Any agent or
framework that emits it gets recording, attribution, and undo for free, plus a
tamper-evident audit trail of what their agent did on a tester's machine.

**Non-goals.** No quota. No tokens. No cost. No rings. No notch. No vendor
endpoints. No sign-in. No cloud.

## 3. What this Mac actually exposes

Measured on 2026-09-09.

| Agent | Installed | Hook events available | Session record on disk | Own checkpoints |
|---|---|---|---|---|
| Claude Code 2.1.266 | yes | `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `SessionStart`, `SessionEnd`, `Stop`, `SubagentStop`, `UserPromptSubmit`, `FileChanged`, `Notification` | `~/.claude/projects/*/*.jsonl`, 212 MB. Per tool call: name, input, result, cwd, session id | `/rewind`, file edits only |
| Codex 0.145 | via SDK and app, no CLI on PATH | `notify` command on `turn-ended` is confirmed. Tool-level hooks: verify against the installed version before relying on them | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Tool calls are `function_call` items named `exec`, `exec_command`, `apply_patch`, `write_stdin`, each with a matching output item | none for shell |
| Gemini CLI | config present, binary not on PATH | `BeforeTool`, `AfterTool`, `SessionStart`, with `matcher` on tool names | `~/.gemini/tmp/<hash>/` | none |
| OpenCode | yes | Plugin API (`tool.execute.before` and `tool.execute.after`) | SQLite `~/.local/share/opencode/opencode.db` plus `storage/` | shadow git repo per project in `snapshot/` |
| Cursor | app installed | `~/.cursor/hooks.json` supports `beforeShellExecution`, `afterFileEdit`, and others. File is absent here, so verify the schema for the installed build | `~/.cursor/agents/`, `~/.cursor/projects/` | editor checkpoints |

Three conclusions:

1. **Hooks give the intent, the filesystem gives the truth.** A hook says the
   agent is about to run `rm -rf build`. Only a filesystem watcher can say what
   that actually deleted. Notchd needs both, and treats the watcher as
   authoritative for what changed and the hook as authoritative for who did it.
2. **Every vendor already writes a machine-readable transcript.** Where hooks
   are missing or the user has not installed them, tailing the transcript gives
   a lower-fidelity record. This is the same fidelity ladder Notchd used, and it
   is reused verbatim: `official` for hooks, `derived` for transcript tailing,
   `unknown` when a change has no attributable session.
3. **OpenCode already proves the storage model.** A content-addressed shadow
   repo per project is enough for file-level undo. Notchd generalises it across
   vendors and adds the shell ledger that no vendor has.

## 4. Architecture

Five parts, all local, no root.

```
 agents ──hooks──▶ notchd-hook (tiny binary) ──unix socket──▶ notchd (daemon)
                                                                  │
 filesystem ──FSEvents────────────────────────────────────────────┤
 transcripts ──tail──────────────────────────────────────────────┤
                                                                  ▼
                                              ledger.sqlite + objects/ (CAS)
                                                                  ▲
                                        Notchd.app (menu bar + timeline window)
```

### 4.1 `notchd-hook`

A single static binary, under 1 MB, that vendors invoke as a hook. It reads the
vendor's JSON from stdin, normalises it to the Notchd event schema, and writes
it to the daemon's socket. It must return in under 20 ms so it never slows an
agent down, and it must exit 0 on any internal failure so a Notchd bug can never
block a tool call. The one exception is the optional guard mode in section 4.6.

### 4.2 `notchd`

A launchd user agent. Responsibilities:

- Accept events on `~/Library/Application Support/Notchd/notchd.sock`.
- On `tool.before` for a mutating tool, snapshot the paths the tool declares
  (edit tools name their file; shell tools get the cwd tree, bounded by the
  limits in 4.4) into the object store, and record a `checkpoint` row.
- On `tool.after`, diff the watched tree against the checkpoint, and record a
  `change` row per path with before and after object hashes.
- Run the FSEvents watcher over every directory any active session has
  declared as cwd, plus the user's home config directories. Attribute each
  batch of events to the session whose tool call is open in that directory,
  or mark it `unattributed`.
- Tail transcripts for agents that have no hooks installed, producing
  `derived` events.
- Prune the object store by policy (default: keep 30 days or 5 GB).

### 4.3 The ledger

SQLite, one file. Tables:

- `sessions(id, vendor, vendor_session_id, pid, cwd, started_at, ended_at, fidelity)`
- `events(id, session_id, kind, tool, args_json, exit_code, started_at, ended_at, fidelity)`
- `checkpoints(id, event_id, root, created_at, object_count, byte_count)`
- `changes(id, event_id, path, kind[create|modify|delete|rename|chmod], before_hash, after_hash, attributed)`
- `reverts(id, created_at, scope_json, result[complete|partial], note)`

Every row is immutable once written. A revert is a new set of events, never an
edit of old ones. That is what makes the ledger an audit trail and not a cache.

### 4.4 The object store

Content-addressed, SHA-256, zstd compressed, one file per blob under
`objects/ab/cdef...`. Directory trees are stored as manifest blobs listing
`(path, mode, hash)`. This is the OpenCode and git model without a git
dependency, so it works on directories that are not repositories and on files
git ignores.

Limits, all configurable: skip any file over 50 MB; skip paths matching a
built-in list (`node_modules`, `.git/objects`, `build`, `DerivedData`, `.venv`,
caches) unless the tool call explicitly names them; cap one checkpoint at
20,000 files, and record `checkpoint.truncated = true` when the cap is hit so
the UI can say so.

### 4.5 Revert

Select a range of changes in the UI. Notchd computes the set of paths, shows
the diff, and on confirm:

1. Takes a fresh checkpoint of the current state first, so a revert is itself
   revertible.
2. Restores each path from its `before_hash`, deletes paths that were created,
   recreates paths that were deleted.
3. Records a `reverts` row with `complete` only if every path in scope was
   restored bit for bit. If any change in the range was a non-file effect (a
   network call, a process started, a Keychain write) the result is `partial`
   and the UI lists exactly what could not be undone.

Rule: Notchd never says "undone" when it means "the files are back". Those are
different sentences, and the second one is the only one it can always prove.

### 4.6 Guard mode, later

Because `notchd-hook` runs before the tool, it can also refuse. An opt-in rule
set (`never let an agent run rm -rf outside the project`, `never touch
~/.ssh`) returns a deny to the vendor's hook protocol. This is Phase 6, not the
MVP, and it is the point where the product stops being only a recorder.

### 4.7 The open protocol

One JSON object per line over the socket, or via `notchd-hook emit` from any
language:

```json
{"v":1,"kind":"tool.before","vendor":"my-agent","session":"abc","pid":1234,
 "cwd":"/Users/me/proj","tool":"shell","args":{"command":"make build"},
 "paths":["/Users/me/proj"],"ts":"2026-09-09T10:00:00Z"}
```

Kinds: `session.start`, `session.end`, `tool.before`, `tool.after`,
`tool.failed`, `note`. That is the whole surface an agent developer needs to
integrate. Publish it as a one-page spec and a three-line example per language.

## 5. The redesign

Notchd's visual language is a dial in glass. Notchd has no percentages, so the
dial has nothing to show. The primary object is time, and the primary verb is
revert. The design starts there.

### 5.1 Principles

- **Time runs left to right, one lane per session.** A person with three agents
  sees three lanes, and can tell at a glance which one touched the file they
  care about.
- **Changes are the atoms, not tool calls.** A tool call is how something
  happened; the file is what happened. Tool calls are shown as the reason
  behind a change, on demand.
- **Every claim carries its fidelity.** Hook-recorded changes draw solid.
  Transcript-derived changes draw hatched. Unattributed filesystem changes draw
  grey, in their own lane labelled "not from any known agent".
- **Revert is always two steps and never one.** Select, preview the diff,
  confirm. There is no single-click undo anywhere in the app.
- **Quiet until something matters.** No animation while agents run. The menu
  bar changes only on a count change or a failed revert.

### 5.2 Surfaces

**Menu bar item.** A monochrome glyph and a short count: `3 · 41`, agents and
changes in the last hour. Clicking opens a compact popover with one row per
active session (vendor, project, last change, time since) and one button:
"Open timeline".

**Timeline window.** The main surface. Three regions:

1. A header with a time range control (last 15 min, hour, today, custom) and a
   project filter populated from session cwds.
2. The lane view. One horizontal lane per session in range, ordered by most
   recent activity. Each change is a small tick coloured by kind (create,
   modify, delete). Hover a tick for path and tool. Drag across a lane, or
   across several lanes, to select a range. Ticks that are part of a checkpoint
   that was truncated show a dot underneath.
3. The inspector. With nothing selected it lists the files most changed in
   range. With a selection it shows the file list, the aggregate diff, the
   tool calls that caused the changes, and the Revert button.

**Revert sheet.** File list with per-file checkboxes, a full diff, the number
of files, and a plain-language line for anything that will not be undone:
"2 shell commands in this range made network requests. Their files will be
restored; their requests cannot be." Confirm restores and writes the
`reverts` row. After it, the sheet reports `complete` or `partial` with the
list.

**Session page.** Click a lane label to see one session as a vertical log:
prompt, tool calls, changes, in order, with the transcript excerpt where the
vendor provides one. This is the debugging view for agent developers.

**Onboarding.** One screen per installed vendor: what Notchd will add to that
vendor's hook config, shown verbatim, with an Install button that writes it.
Nothing is installed silently. A vendor with no hook support shows "Notchd will
read this tool's transcript instead, at reduced fidelity" and explains what
that loses.

### 5.3 Visual system

Keep Notchd's typography scale and its light, dark, and automatic appearance.
Drop the glass surface and the rings. Use a flat, high-contrast surface so
diffs read cleanly. Three semantic colours only: create, modify, delete. One
attention colour for a failed or partial revert. No provider brand colours;
vendors are told apart by a small monochrome glyph and a label, reusing the
glyph outlines Notchd already has.

## 6. Implementation plan

Each phase ends in something a person can run. No phase depends on a vendor
feature that has not been verified on this machine in Phase 0.

### Phase 0: verify the ground (2 to 3 days)

- [x] Claude Code payloads, read from its own schema (2.1.266,
      `entrypoints/sdk/coreSchemas.ts`): every hook carries `session_id`,
      `transcript_path`, `cwd`, optional `permission_mode`, `agent_id`,
      `agent_type`; tool hooks add `tool_name`, `tool_input`, `tool_use_id`,
      `tool_response` on PostToolUse, `error` on PostToolUseFailure. No
      timestamp, so the receipt time is the event time. Exit code 2 blocks.
- [ ] Repeat for Gemini CLI `BeforeTool` and `AfterTool`.
- [ ] Find whether the installed Codex supports tool-level hooks. If not, prove
      that tailing `rollout-*.jsonl` yields `function_call` and
      `function_call_output` pairs in real time, and measure the lag.
- [ ] Write a five-line OpenCode plugin using `tool.execute.before` and confirm
      it fires.
- [ ] Locate Cursor's current hooks schema and confirm `beforeShellExecution`
      fires on this build.
- [ ] Measure FSEvents latency and event coalescing on a `git reset --hard` of
      a 5,000-file repo.
- [ ] Decide the daemon language from these results. Default: Swift, sharing
      types with the app. Alternative: Rust for the hook binary if Swift's
      startup exceeds 20 ms.

Exit criterion: a table like the one in section 3 with every "verify" replaced
by a measured answer.

### Phase 1: record Claude Code (done 2026-09-09)

- [x] Same repository, `notchd` branch. Kept from Notchd: `Updater.swift`,
      the Makefile release flow, the `Fidelity` idea. Everything else deleted
      and rewritten.
- [x] `notchd-hook` binary. It forwards the raw payload in an envelope rather
      than normalising, so an adapter fix never needs a reinstall. Darwin
      only; measured at 3 to 5 ms per call with the server up, 52 ms cold with
      no server, exit 0 in every case.
- [x] Socket server, ledger schema, `sessions` and `events` tables. The app
      process hosts the recorder for now; a separate launchd daemon waits until
      the recorder has to outlive the app.
- [x] Set-up window that shows the exact hook JSON and writes it only on
      Install; Remove restores the file.
- [x] 58 tests: protocol round trip, Claude adapter fixtures, append-only
      ledger, socket framing, ingest of garbage and unknown vendors, hook
      config merge and removal, palette contrast, updater configuration.
- [x] End to end: seven Claude-shaped hook events plus a native `emit` from a
      third-party agent recorded with correct kinds, paths, and errors.

One lesson from the end-to-end run: the socket protocol says one object per
line, but a payload forwarded verbatim can carry newlines of its own. The
server now frames on complete JSON rather than on bare newlines.

### Phase 2: snapshot and revert (done 2026-09-09)

- [x] Object store: SHA-256 names, LZFSE rather than zstd because it is in
      the system, with the size and file-count limits from 4.4. Pruning is
      not written yet; the store is small (32 KB after the exit-criterion run)
      and pruning needs the reference walk from checkpoints and changes.
- [x] Checkpoint on `tool.before` for every tool that declares paths, diff on
      `tool.after` and `tool.failed`. Pairing is by tool call id, then by
      order for vendors that send none, then through the ledger for a
      before-event recorded by a previous run of the app.
- [x] A baseline snapshot of the working directory on `session.start`, so the
      first checkpoint is fast and unattributed changes have an earlier copy.
- [x] FSEvents watcher over the working directories of active sessions.
      Reports inside an open call's roots are left to that call's diff;
      everything else is an unattributed change compared against the last
      copy in the stat cache. Paths Notchd is about to restore are suppressed
      so a revert is not recorded as somebody else's work.
- [x] Revert engine: earliest state per path, a checkpoint of the current
      state first, bit-for-bit verification, `complete` only when every path
      verified, shell commands in the range named in the plan.
- [x] `notchd` command line in `Contents/Helpers`: `sessions`, `changes`,
      `revert` with `--last`, `--session`, `--unattributed`, `--dry-run`,
      `--yes`.
- [x] 99 tests, including the plan's cases: create, modify, delete, symlink,
      and mode round trips; a revert of a revert; truncated checkpoints;
      a change with no open call landing as unattributed; a missing copy
      making the result partial.
- [x] Exit criterion met end to end through the real hook binary and the
      real CLI: `rm -rf src` and an edit came back bit for bit, a file made by
      hand was recorded as unattributed and left alone, the ledger says
      `complete`.

Three changes to the design, made while building:

1. **The hook waits for an acknowledgement.** A checkpoint has to finish
   before the tool runs, and the hook exiting is what lets the tool run. So
   the hook now half-closes its socket and reads until the app answers, with
   a four-second cap after which it exits 0 anyway. A checkpoint that outruns
   the cap is recorded as `late`.
2. **Two socket lessons.** On macOS an accepted socket inherits the listening
   socket's non-blocking flag, so it is cleared per connection. And a write
   to a peer that has already closed raises SIGPIPE despite `SO_NOSIGPIPE`,
   so the server ignores the signal for the process.
3. **The CLI lives in `Contents/Helpers`.** A product named `notchd` copied
   into `Contents/MacOS` overwrites the app's own `Notchd` executable on a
   case-insensitive filesystem.

### Phase 3: the timeline app (done 2026-09-09)

- [x] Menu bar item with the count. The popover is a menu for now: Open
      Notchd, Set Up Agents, Check for Updates, Quit.
- [x] Timeline window: range control (15 min, hour, today, week), one lane
      per session plus the unattributed lane, ticks by kind with solid,
      dashed, and faded styles for the three fidelities, ticks on one pixel
      column merged into a wider mark in the most serious kind, hover
      readout, drag selection across one or more lanes.
- [x] Inspector: the files in the selection with net kind and count, or the
      most changed files in the range with nothing selected; a line diff of
      the chosen file with folded unchanged runs, binary and too-large
      cases; the tool calls that caused the selection.
- [x] Revert sheet: per-file ticks, impossible rows unticked with the reason,
      the shell commands whose non-file effects are not undone, confirm,
      then the result with every failure named.
- [x] Session page: prompts, tool calls, and the files each changed.
- [x] Light and dark; every colour held to 3:1 by test.
- [x] Render tests for each surface in both appearances, through a real
      window so AppKit-backed controls draw too. `NOTCHD_RENDER_DIR` writes
      them as PNGs to look at.
- [x] Store pruning, left over from Phase 2: blobs unreferenced within thirty
      days are removed; ledger rows never are.

Exit criterion met: the Phase 2 scenario runs by mouse, with the diff shown
before confirmation, verified in the model tests and by looking at the
renders.

### Phase 3b: the notch (done 2026-09-09)

A correction to section 2 and section 5 of this plan. "No notch" was wrong:
the edge notch is the one part of Notchd that was worth keeping, and it is
the right ambient surface for Notchd. The timeline window is the deep
surface; the notch is what you glance at and reach for.

- [x] The chrome kept from Notchd, cleaned to the docstring rule: edge and
      placement in stack space, panel geometry against the visible frame,
      the welded shape with flares, the non-activating panel, the hosting
      view that keeps the rest of the panel a hole, the motion vocabulary,
      the glass surface, and the hardware-notch join on the top edge.
- [x] New content: header with the counts and a gear, one row per live
      session with per-kind counts from the last hour, the last few files
      touched by anyone with unattributed ones faded, and a footer with
      Open timeline and Revert last 10 min. The revert action opens the
      timeline with the span selected and the sheet up: still two steps.
- [x] The view model lays out the content box in ordinary top-left
      coordinates (only the shape rotates) and hands the same rects to the
      view and to the window controller's hit test, so nothing is drawn that
      cannot be clicked or clicked that is not drawn.
- [x] Click to pin, right-click menu, four edges, three visibilities, all
      persisted in Preferences and applied live from the settings window.
- [x] Tests for geometry, placement, the resting and open shapes, content
      growth, targets, rows, copy, preferences, and renders of every edge
      open and at rest plus the hardware-joined top.

### Phase 4: Codex and Gemini CLI (done 2026-09-09)

Phase 0 answers, measured on this machine:

- **Codex** is the desktop app (`originator: Codex Desktop`, cli 0.145)
  with no binary on the path and no hook support anywhere in `~/.codex`.
  The rollouts are the only source. Shapes confirmed: `session_meta`
  (session id, cwd, timestamp), `turn_context` (cwd per turn),
  `response_item` with `function_call` (name, arguments as a JSON string,
  call_id), `custom_tool_call` for `exec` and `apply_patch` (input as
  text), and the two `_output` types paired by call_id. Every line carries
  a timestamp.
- **Gemini CLI** is configured but not installed here, and the hook scripts
  its settings name do not exist, so its payload could not be recorded.
  The adapter follows Gemini's documented hook shape, which mirrors Claude
  Code's, and accepts both Gemini's tool names and Claude-style ones. This
  is the one adapter not verified against a live vendor, and the README
  says so.

- [x] Gemini adapter through `BeforeTool` and `AfterTool`, official
      fidelity, timestamp from the payload when present.
- [x] Codex: a rollout tailer at derived fidelity. A file seen for the
      first time is adopted at its end, after its first line for the
      session and cwd, so appending to an old transcript never replays
      hours of history. Shell calls declare their workdir; apply_patch
      declares every file its headers name. Nothing is installed into
      Codex, and a preference turns the tailing off entirely.
- [x] One hook-settings layer for every vendor whose settings file takes
      command hooks; the settings window has a card per vendor and a
      switch for Codex.
- [x] The timeline already drew derived ticks dashed; Codex sessions now
      exercise it.
- [x] 157 tests, with the Codex parser checked against lines in the exact
      shape this machine's transcripts use.

Exit criterion met for Claude Code and Codex in one timeline with the
fidelity difference visible. Gemini joins them on the first machine that has
it installed; if its payload differs from the documented shape, the adapter's
fixture tests are where it shows.

### Phase 5: OpenCode, Cursor, and the open protocol (done 2026-09-09)

Phase 0 answers: OpenCode 1.x is installed here with `@opencode-ai/plugin`
1.0.25 in its cache, whose types give `tool.execute.before` with
`{tool, sessionID, callID}` and `{args}`, `tool.execute.after` with
`{title, output, metadata}`, and an `event` handler that sees
`session.created`. Cursor is not installed on this machine, only its old
configuration directory, so its hooks follow Cursor's documentation.

- [x] OpenCode: not an npm package but a plugin file Notchd writes into
      `~/.config/opencode/plugin/`, shown in full before it is written. It
      sends protocol events through `notchd-hook emit` and awaits the
      acknowledgement, so the checkpoint lands before the tool runs.
      Official fidelity. The generated JavaScript is syntax-checked in the
      tests with whichever of bun or node the machine has.
- [x] Cursor: entries in `~/.cursor/hooks.json` in Cursor's documented
      format, an adapter for its documented payloads, and the hook binary
      answering Cursor's before-hooks with an allow. Cursor has no
      before-edit hook, so file edits are after-only tool calls: the
      recorder compares each declared file with the last copy it holds.
      Unverified against a live Cursor, and the settings window says so.
- [x] `PROTOCOL.md`, with `notchd-hook emit`, the field table, and what
      Notchd does with each kind; `examples/` with Python, TypeScript,
      shell, and a minimal agent whose integration is three lines.
- [x] One `AgentIntegration` protocol behind the settings window, so a
      card is the same for a hook vendor, a plugin, and a hooks file.
- [x] The product name: Notchd, throughout. An earlier build's hook
      entries are recognised for removal and replaced on Install; its data
      directory is moved into place on first launch.

Exit criterion, integrating from the spec alone in under fifteen minutes,
is the reader's to judge; the minimal agent is the test case.

### Phase 6: guard mode and release (guard done 2026-09-09)

- [x] Rule engine: path globs and command globs, deny or ask, kept in
      `guard.json` beside the ledger, off by default, seeded with a few rules
      on first switch-on. Only hook-recorded `tool.before` events are judged;
      a transcript-derived call has already run.
- [x] The acknowledgement the app already sends became the decision:
      `ok`, `ask <reason>`, or `deny <reason>`. The hook translates it into
      each vendor's own refusal: Claude Code a `hookSpecificOutput`
      permission decision, which also carries `ask` to Claude Code's own
      prompt; Gemini CLI exit status 2 with the reason on stderr; Cursor a
      `permission` object; the OpenCode plugin and any native emitter a
      plain JSON decision, which the plugin turns into a thrown error.
      Silence is still allow, so the hook can never block a call by failing.
- [x] A denied call is recorded with the decision and skips the checkpoint.
      The session page says "blocked by guard".
- [x] The rules editor in the settings window, with the limits stated on
      the card: only what agents declare, only the user's own rules, never
      Codex.
- [x] Version 2.0.0, build 3, so an installed copy of the earlier app under
      this name updates to it.
- [ ] Signed, notarized DMG and the Sparkle feed: the maintainer's step, with
      `make release-local` once the Developer ID certificate exists.
- [ ] A two-minute recording of the `rm -rf src` recovery.

## 7. Invariants

Carried from Notchd and extended:

1. Never display a fidelity higher than the source supports.
2. Never write to a vendor's config without showing the exact text first.
3. Never block a tool call because of a Notchd failure. Guard mode blocks only
   because of a user's rule.
4. Never report `complete` unless every path in scope was restored bit for
   bit. Non-file effects are always named, never summarised away.
5. Never leave the machine: no network code in any target.
6. Never read a transcript for a vendor the user has switched off.

## 8. Risks and how each is handled

| Risk | Handling |
|---|---|
| Two agents in one directory at the same time | Attribution uses the open tool call's declared paths first, cwd second. Ambiguous changes are shown in both lanes with a badge, never silently assigned |
| Snapshot cost on large trees | Limits in 4.4, plus a warm manifest cache so an unchanged tree costs one stat per file, not one read |
| Vendor changes its hook schema | Adapters live behind fixture tests. A schema mismatch downgrades to transcript tailing and shows a banner instead of failing |
| Reverting something the user changed by hand in the same range | Hand edits appear in the unattributed lane and are excluded from a revert by default. Including them is an explicit checkbox |
| Databases and other non-file state | Out of scope for revert, in scope for the ledger. The sheet names them |
| Users mistake it for a sandbox | The onboarding says in one sentence what it does not prevent, and guard mode is labelled as rules the user wrote, not protection Notchd promises |

## 9. What this is not, so the scope stays honest

Not a quota meter. Not a cost tracker. Not an orchestrator that runs agents.
Not a sandbox. Not a git client. Not a cloud service. If a feature idea belongs
to one of those, it goes in a different plan.
