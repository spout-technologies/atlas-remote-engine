# Atlas Remote — Upstream Divergence Ledger

**Purpose:** Atlas Remote is a hard fork of RustDesk. We evolve our own product (UI, hub integration,
routing, updater) but must keep ingesting upstream **security and codec/capture fixes**. This ledger is the
map of what we own outright vs. what we track, and the record of each ingestion.

**Fork baseline:** RustDesk tag **1.4.8** (`3c574a41`), `hbb_common` `387603f4`. Current fork: see `src/version.rs`.
**Remotes:** `origin` = `spout-technologies/atlas-remote-engine`; `upstream` = `rustdesk/rustdesk` (added 2026-07-16,
for CVE diffing — we do NOT merge upstream, we cherry-pick into tracked subsystems).

## Subsystem ownership map

### OWN outright — do NOT track upstream (upstream changes here are noise; ours is the source of truth)
| Subsystem | Notes |
|---|---|
| `flutter/lib/**` UI + rebrand | Atlas Design pixel-rebuild, wordmark/theme, ab-2.0 client UI |
| ab-2.0 hub address-book client (`ab_model.dart`, `/api/ab/*`) | Our contract with the Atlas hub |
| In-app updater (`src/updater.rs`) + agent-driven update | Repointed off api.rustdesk.com; draft-gated fleet serve |
| Per-session `lc` routing / `id@server?key=` + `&alt=` failover (`src/client.rs`) | Our multi-region seam |
| Relay orchestration (hub-side) + rendezvous baked config | Data-driven region model |
| Atlas icon/scheme federation (`atlasremote://`, `res/*` icons, `logo*.svg`) | Brand identity |
| Headless controlled-session entrypoint | `ATLAS_TASK9_HEADLESS_ENTRYPOINT_SPEC.md` |

### TRACK upstream — ingest security/correctness fixes on a cadence
| Subsystem | Why we track | Baseline |
|---|---|---|
| `libs/scrap/**` | Capture + codecs (VP8/9, H264/5, AV1) — perf + CVEs | vendored @ 1.4.8 |
| `libs/hbb_common/**` | Rendezvous/relay wire protocol, crypto, `secure_tcp` | `387603f4` |
| `src/platform/**` | Screen capture, TCC (macOS), Windows service/install | 1.4.8 |
| `rustdesk-org/*` git deps | `magnum-opus`, `rdev`, `kcp-sys`, `cpal`, `parity-tokio-ipc` | pinned in Cargo.toml |
| Relay server image | `rustdesk/rustdesk-server` — we fork for ip_blocker/limits (A4) | 1.1.15 |

## Ingestion log
| Date | Upstream range | Subsystem(s) | Commits ported | Notes |
|---|---|---|---|---|
| _(seed)_ 2026-07-16 | fork @ 1.4.8 | — | — | Ledger created; `upstream` remote added. First triage due 2026-Q4. |

## Cadence
Quarterly security-triage cherry-pick + ad-hoc CVE watch (RustDesk GitHub Security Advisories + the vendored
`rustdesk-org/*` deps). Runbook: `docs/runbooks/UPSTREAM_INGESTION.md`. Each ingestion appends a row above.
