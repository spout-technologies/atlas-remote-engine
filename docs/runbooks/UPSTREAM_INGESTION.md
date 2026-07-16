# Runbook — Ingesting Upstream RustDesk Fixes

Quarterly (or on a CVE advisory). We cherry-pick into TRACKED subsystems only; we never merge upstream wholesale
(the fork has diverged too far — per-session `lc` routing, hub ab-2.0 API, updater, headless entrypoint, rebrand).

## Steps
1. `git fetch upstream --tags`
2. Read the RustDesk **CHANGELOG** and **GitHub Security Advisories** since the last ledger row.
3. Filter to the TRACKED subsystems in `UPSTREAM_DIVERGENCE_LEDGER.md` (scrap/codecs, hbb_common protocol/crypto,
   platform capture/TCC/service, the `rustdesk-org/*` deps). Ignore UI/branding/ab/updater/routing changes — we own those.
4. Open a triage issue listing candidate commits (CVE / codec / protocol-correctness). Anything not security- or
   correctness-critical waits.
5. Branch off `main`; `git cherry-pick <sha>` (or hand-port when the file has diverged). Resolve against our vendored
   `libs/`.
6. Re-run `bridge.yml` (flutter_rust_bridge codegen) if any FFI signature changed.
7. Both `atlas-remote-macos.yml` and `atlas-remote-windows.yml` green (they publish DRAFTs — see the release runbook).
8. Smoke a governed session: connect → screen → input → clean teardown.
9. Append a row to the ledger (date, upstream range, subsystems, ported commits, notes).
10. Tag `v*` / `win-v*` → hardware-verify the drafts → publish (never skip the hardware gate).

## Relay server (separate)
The forked `rustdesk-server` image (ip_blocker/limits parameterised — Workstream A4) tracks upstream
`rustdesk/rustdesk-server` the same way: fetch, diff, cherry-pick security fixes onto our pinned 1.1.15 base,
rebuild the GHCR image, repoint JHB first (soak ≥1 week) then EU.
