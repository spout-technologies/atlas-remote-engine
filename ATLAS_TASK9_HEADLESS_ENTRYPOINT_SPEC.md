# Task 9 — Headless engine entry point + `--session-target` (execution spec)

**Status:** IMPLEMENTED on branch `feat/task9-headless-entrypoint` (2026-07-09) —
`parse_atlas_headless` + `run_atlas_headless` + the `#[cfg(windows)]`
`atlas_bind_session_target` seam in `src/core_main.rs` (additive; +240 lines).
Locally verified on macOS x86_64: **Phase A parser 7/7 unit tests PASS** and the
full `librustdesk` crate compiles natively via `cargo test` — after a local
`vcpkg install` of vpx/aom/yuv/opus @ x64-osx, so the earlier "cannot
`cargo build`/`cargo test` in a macOS sandbox" assumption is empirically FALSE once
vcpkg is present. The `#[cfg(windows)]` Phase C shape additionally **cross-compiles
and links for `x86_64-pc-windows-msvc`** via `cargo-xwin` (LLVM/LLD + a clang-cl
`-Wno-error=implicit-function-declaration` shim for mozjpeg-sys). STILL human-gated:
the full flutter Windows build (fork CI — Flutter 3.24.5 + bridge + MSVC codec libs;
the whole-crate cross-build is blocked on macOS by third-party native deps, not our
code) and the §6 live E2E (Windows Server + workstation + relay). **Do not merge to
the fork's `main`** without both. (`PREFLIGHT.md` marks the fork build DEFERRED;
`engine.go` calls it "the human-gated finish list".)

**Repo:** `/Users/humphreytheodorek/StudioProjects/atlas-remote-engine` (branch off
`feat/atlas-ui-1.5.0`). Separate git repo from Atlas OS — its own branch, commit,
and CI. All line numbers below are from the code as it exists now (verified
2026-07-09).

---

## 1. Why this exists / the contract already in the field

The Atlas Go agent (main repo, `agent/internal/remote/engine.go`) already spawns
this engine binary at arm's length via `os/exec` with a fixed contract:

- **argv:** `--mode <view|input_control>`; when a relay is present:
  `--rendezvous <host> --relay <host> --relay-key <pubkey>`; and (Task 8, just
  landed) `--session-target <console|current_user>` **only when non-empty**.
- **stdin:** one line — the one-time session ticket/grant (the only secret; never
  argv).
- The agent locates the binary as `atlas-remote-engine[.exe]` next to itself (or
  `$ATLAS_REMOTE_ENGINE`) and treats its **absence as graceful degradation**
  (`locateEngine()` → false → `Handle()` reports `engine_unavailable`, never
  crashes).

**None of these flags are parsed by the engine today.** `core_main.rs` peels off
only four boolean flags (`--elevate`, `--run-as-system`, `--quick_support`,
`--no-server`, lines 68-75) and matches `args[0]` against a fixed subcommand set
(lines 131-748). An unknown flag like `--session-target console` currently falls
through to `return Some(empty)` → the process tries to start the **Flutter GUI**
(which fails to open a window headlessly but does **not** crash / exit non-zero).

**Deploy-ordering consequence (safe):** because the current binary tolerates the
unknown flags silently, the Task 8 agent emitting `--session-target` ahead of this
work **breaks nothing** in the field — it is simply ignored until this ships. Keep
that property: the new parser must **log-and-ignore unrecognised flags**, never
hard-error, so hub/agent/engine can version independently forever.

---

## 2. The one architectural decision (confirm before building)

`--session-target console|current_user` is **controlled-endpoint (server-side)**
machinery: it selects which Windows **window-station / session** the controlled
host binds its server process to. It is NOT a controlling-side (viewer) concern.

This matches the deployment: the Go agent spawns this engine **on the managed
endpoint** after consent; the operator's controller joins from elsewhere via the
`atlasremote://join/...` URI the hub emits. So the engine-on-the-endpoint is the
**controlled** side, and `--session-target` drives the server-side session-binding
chain (§4).

→ **Decision to confirm:** the headless entry point stands up a **controlled
server** (RustDesk `--server`/`--service` family), parameterised by the ticket +
relay + mode + session-target — it does **not** stand up an outgoing viewer.
Everything below assumes this. If that's wrong, stop — the whole seam changes.

---

## 3. Every mechanism this needs ALREADY EXISTS (cited)

| Need | Where it lives now |
|---|---|
| Manual argv loop / subcommand dispatch to extend | `src/core_main.rs:50-81` (peel loop), `:131-748` (dispatch chain) |
| Existing `#[cfg(test)] mod tests` to mirror for a parser test | `src/core_main.rs:951-985` (`fn args(&[&str])` helper at 955-957) |
| Controlled-server entry (incoming side) | `--server`/`--service`/`--cm` arms in `core_main.rs`; `run_service`/`launch_server` in `src/platform/windows.rs` |
| view vs input_control | the per-session **`view-only`** toggle: read `src/client.rs:2277`; stored `config.view_only.v` (`:2158-2167`, `:2369-2370`) |
| rendezvous/relay/key injection | today **global config** (`custom-rendezvous-server`, `relay-server`, `key`), written only via `--config`/`--option` (`core_main.rs:507-536`), root+installed. Relay key `RS_PUB_KEY` is **baked at build** (`PREFLIGHT.md:12`). `force_relay` is the only per-session relay knob (`initialize(..., force_relay, ...)`, `src/client.rs:1791`) |
| enumerate console/RDP sessions | `get_available_sessions(name)` `src/platform/windows.rs:1132`; C shim `get_available_session_ids` `windows.cc:642`; console first via `get_current_session(FALSE)` (`WTSGetActiveConsoleSessionId`) `windows.rs:1146` |
| `is_share_rdp()` / `set_share_rdp()` | `windows.rs:1042` / `:1046-1054` (registry `share_rdp`); gates multi-session at `connection.rs:1906`, `:3427` |
| pick/switch session server → window-station | `Data::UserSid(Option<u32>)` `ipc.rs:334`; sent by `connect_to_user_session()` `ipc.rs:2008-2010`; **handled** in `run_service` loop `windows.rs:719-733` → `launch_server(session_id, true)` (relaunches per-session server bound to the chosen session) |
| console/server SKU checks | `is_physical_console_session()` `windows.rs:1069-1078`; `is_windows_server()` `windows.rs:559` |
| interactive picker to BYPASS | `showWindowsSessionsDialog` (Flutter) → `session_send_selected_session_id` (`flutter_ffi.rs:927-929`) → `send_selected_session_id(sid)` (`ui_session_interface.rs:1595-1602`) sets `LoginConfigHandler::selected_windows_session_id` (`src/client.rs:1762`) + sends `Misc::SelectedSid` |

**The single net-new seam:** a non-interactive way to pre-select the session
target (console vs current-user) instead of showing `showWindowsSessionsDialog`.
The server-side auto-branch already fires without a dialog when the pre-set
selection equals `current_sid` (`ui_session_interface.rs:1858-1859`) — but shows
the dialog when it differs (`:1861`). So a true "pre-choose and never prompt"
needs a small change at that branch, OR (cleaner for a headless controlled server)
resolve the target sid up front and call `connect_to_user_session(Some(sid))`
directly (`ipc.rs:2008`), which the elevated `run_service` already honours
(`windows.rs:719-733`).

---

## 4. Implementation plan (additive, minimal)

**Phase A — arg parsing (pure, unit-testable, do first).**
1. In `core_main.rs`, add a small struct `AtlasHeadlessArgs { mode, rendezvous,
   relay, relay_key, session_target }` (all `Option<String>`), and a pure
   `fn parse_atlas_headless(args: &[String]) -> Option<AtlasHeadlessArgs>` that
   returns `Some` only when `--mode` is present (the sentinel that this is an
   Atlas headless spawn, not a normal invocation). Recognise `--mode`,
   `--rendezvous`, `--relay`, `--relay-key`, `--session-target`; **ignore unknown
   flags with a `log::warn!`, never error** (§1 property).
2. Validate `session_target ∈ {console, current_user}` — on any other value,
   `log::warn!` and treat as unset (mirrors the hub's own strict-then-default
   posture; a bad value must not silently pick the wrong session).
3. Read the one-line ticket from **stdin** (`std::io::stdin().read_line`), trimmed.
   Never accept the ticket via argv.
4. Add a `#[cfg(test)] mod tests` mirroring `core_main.rs:951-985`: cover
   `--mode` presence gating `Some`/`None`, each flag parsed, unknown-flag
   tolerated (returns `Some`, no panic), invalid `--session-target` → unset,
   ticket-not-in-argv. **These tests still link the native crate** — they run in
   CI (Windows runner), not locally.

**Phase B — wire the parsed args into a controlled server.**
5. Dispatch: near the top of the `core_main` arg handling (before the existing
   `args[0]` chain, since `--mode` won't match any existing arm), if
   `parse_atlas_headless` returns `Some`, branch into a new
   `run_atlas_headless(args, ticket)` instead of falling through to the GUI.
6. Inject rendezvous/relay/key: set the global config options
   (`custom-rendezvous-server`, `relay-server`, `key`) from the parsed values via
   the existing `Config::set_option` path (same as `--option`, `core_main.rs:521`)
   **before** starting the server — scoped to this process. (Relay key: if the
   baked `RS_PUB_KEY` is already correct for the Atlas relay, `--relay-key` may be
   redundant/confirmatory — confirm against `PREFLIGHT.md:12` and decide whether to
   honour it or assert-match it.)
7. Apply `mode`: `view` → set the session `view-only` on; `input_control` → leave
   default (`src/client.rs:2158-2167`).
8. Start the controlled server the same way the `--server`/`--service` path does
   (reuse `run_service`/`launch_server`, do not reimplement).

**Phase C — session targeting (Windows-only, `#[cfg(windows)]`).**
9. Resolve the target sid from `--session-target`:
   - `console` → `get_current_session(FALSE)` (the active console sid,
     `windows.rs:1146` / `windows.cc:547`).
   - `current_user` → the current interactive user session (the existing
     `get_current_session(share_rdp())` default, `windows.rs:675`).
   - unset/`auto` never reaches here (hub resolves `auto` before dispatch; if it
     ever does, default to current-user — the safer, non-console default).
10. Ensure the `is_share_rdp()` precondition is satisfied **for this invocation
    only** (the console/RDP distinctness logic gates on it at `connection.rs:1906`,
    `:3427`) — set it in-process rather than writing the persistent registry value
    where possible; if the registry write is unavoidable, restore the prior value
    on exit.
11. Drive the selection non-interactively: call
    `connect_to_user_session(Some(target_sid))` (`ipc.rs:2008`) — the elevated
    `run_service` loop relaunches the per-session server bound to that
    window-station (`windows.rs:719-733`). Do **not** invoke
    `showWindowsSessionsDialog` (there is no GUI in this path).
12. Non-Windows: `--session-target` is a no-op (`#[cfg(not(windows))]`) — console
    vs RDP session is a Windows-only concept; log-and-ignore.

**Phase D — CI / arm's-length.**
13. `.github/workflows/atlas-remote-windows.yml` builds via
    `python build.py --portable --hwcodec --flutter` on `win-v*` tags; keep the
    **dark-mode guardrail** step (`:118-125`) green and the `Cargo.lock` version
    sync (`:127-141`) intact on any version bump (`cargo build --locked`).
14. The arm's-length *import* invariant lives in the **Atlas agent** repo
    (`go list -deps | grep -i rustdesk`), not here — nothing in this change should
    make the Go agent import the fork. Keep `agent/scripts/check-armslength.sh`
    green over there (it already is; this is a pure engine-side change).

---

## 5. Scope guardrails

- **Do NOT** stand up an outgoing viewer — this is the controlled server (§2).
- **Do NOT** implement the approve-mode / permanent-password / consent-bypass
  config here (that's the §6.3-spec "unattended fleet" config path). The hub
  already governs consent via `consent_required` per session; the engine only
  needs mode + relay + session-target for this task. The password/approve-mode
  mechanisms exist (`libs/hbb_common/src/password_security.rs`,
  `config/permanent_password.rs`; settable via `--password`/`--option`/
  `--import-config`, `core_main.rs:418-452,521-536`) — reserve for a later task.
- **Additive only** — don't disturb the existing `--server`/`--service`/GUI paths.
- Keep unknown-flag tolerance (§1) — never hard-error on an unrecognised flag.

---

## 6. Verification (the human-gated part — TK's hardware)

Unit tests (Phase A) run in CI. Full proof needs live hardware:

1. **Build gate:** the `win-v*` tagged build is green (dark-mode guardrail +
   `--locked` Cargo.lock).
2. **Enrol** a Windows **Server** SKU + a Windows workstation via the normal Atlas
   local-agent flow; drop the built `atlas-remote-engine.exe` next to each agent.
3. **Baseline / no regression:** a device with NO unattended policy → start a
   session → the on-endpoint consent prompt still appears (Go agent
   `promptConsent`), engine spawns only after `state=='active'`.
4. **Console targeting:** RDP into the server first (establish an RDP session),
   then start an Atlas session with `sessionTarget: 'console'` (or `'auto'` with
   `rmm_devices.role='server'`) → the session lands on the **physical console
   session**, verifiably distinct from the RDP session (`qwinsta`/`query session`
   on the box, or visibly different desktop).
5. **current_user targeting:** on the workstation, `sessionTarget:'current_user'`
   → attaches to the logged-in interactive session.
6. **Unknown-flag tolerance:** an OLDER engine build (pre-this-work) receiving
   `--session-target` must still start (proving the field-safety in §1) — or
   confirm the deployed fleet has no engine yet (today's state).
7. **argv/stdin hygiene:** confirm (process inspection) the ticket is on stdin,
   never in the command line / logs.

---

## 7. Effort read

This is a **net-new entry point stand-up**, not a tweak — but every underlying
mechanism exists and is cited (§3), so the work is *wiring + one small
non-interactive session-select seam*, concentrated in `core_main.rs` (parse +
dispatch) and a `#[cfg(windows)]` session-resolve helper. Realistic size: a few
hundred lines + the parser tests. The gating cost is the **toolchain + live
verification**, not the code volume — which is exactly why it's the human-gated
task in the plan.
