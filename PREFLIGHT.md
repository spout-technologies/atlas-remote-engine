# Atlas Remote Engine — CI Preflight & Secret Manifest

Everything the `spout-technologies/atlas-remote-engine` CI needs. Keep the AGPL
toolchain + build logs OUT of the private Atlas tree — this is a separate repo.

## 0. Repo creation (one-time, human-gated)

1. Create `spout-technologies/atlas-remote-engine` (PRIVATE in the Spout org;
   flip PUBLIC at first Release to satisfy AGPL corresponding-source).
2. `git subtree`/copy RustDesk at a pinned release tag; preserve its `LICENSE`.
3. Rebrand; bake the Spout relay: `RENDEZVOUS_SERVER=<hbbs host>`,
   `RS_PUB_KEY_VAL=<Ed25519 relay public key>` (RustDesk PR #2810).
4. Replace the scaffold `LICENSE` with the full AGPL-3.0 text.
5. Copy `.github/workflows/*`, `fastlane/*`, this file.

## 1. macOS signing secrets (Repository → Settings → Secrets → Actions)

| Secret | What | Source |
|---|---|---|
| `MACOS_DEVELOPER_ID_P12_BASE64` | base64 of the Developer ID Application **.p12** | Exported from `ht@humphreytheodore.com` keychain (Xcode; NOT API-mintable) |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | .p12 export password | — |
| `MACOS_KEYCHAIN_PASSWORD` | ephemeral CI keychain password | any strong random |
| `ASC_KEY_ID` | App Store Connect API **Key ID** | `N4PNMP87QA` (Torque team, wired) |
| `ASC_ISSUER_ID` | ASC API **Issuer ID** | `98e56ea0-…` |
| `ASC_KEY_P8_BASE64` | base64 of the ASC `.p8` private key | ASC → Users and Access → Integrations |
| `APPLE_TEAM_ID` | Developer Team ID | `3LPWW88GNW` (Torque Consulting) |

> Developer ID certs **cannot** be minted via API/Fastlane match ("only the
> Account Holder" → Xcode). Everything AFTER the cert exists is automated here.

## 2. Windows signing secrets (HELD until funded)

| Secret | What |
|---|---|
| `WINDOWS_CODE_SIGN_PFX_BASE64` | base64 of the code-signing **.pfx** (EV/OV or Azure Trusted Signing export) |
| `WINDOWS_CODE_SIGN_PFX_PASSWORD` | .pfx password |

**Absent → the workflow ships UNSIGNED and emits a `::notice title=Windows
signing HELD`.** Present → the signing step auto-activates. No workflow edit
needed either way.

## 3. Publishing

`GITHUB_TOKEN` (auto-provided) handles Releases + asset upload. **No GCS/WIF, no
IAM** — dropped by design (v1.1 §1.4). Each Release carries: signed macOS
`.dmg`/`.pkg`, held Windows `.msi`/`.exe`, `SHA-256SUMS`, AGPL corresponding-
source tarball.

## 4. macOS signing corrections baked into the Fastfile (v1.1 §1.4)

- Build **universal** (x86_64 + arm64); sign **inside-out** (hardened runtime +
  entitlements) with `xcodebuild -exportArchive` + a **Developer ID options
  plist** (the naive `Frameworks/**` glob misses nested Flutter helper mach-O).
- `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" <kc>`
  after import, or headless `codesign` hangs.
- **Notarize the `.app`/`.dmg` as its OWN submission** before stapling — a
  `.pkg` ticket does not cover a `.dmg` (Error 65).
- Entitlements: `network.client`, `network.server`, `cs.allow-jit`,
  `cs.disable-library-validation`, `device.audio-input`.
- **Screen Recording + Accessibility are TCC grants** (runtime + Info.plist
  usage strings), **not entitlements**, and TCC resets when the signing identity
  changes → pin the Developer ID from day one.

## 5. Arm's-length invariant (CI-enforced, not asserted)

- `ci-invariant.yml` (this repo): the engine builds to its **own** binary; the
  installer ships **two distinct files**.
- `agent/scripts/check-armslength.sh` (Atlas agent repo CI): the agent Go module
  graph contains **no** RustDesk/fork import (`go list -deps | grep -i rustdesk`
  must be empty).

## 6. DEFERRED (human-gated — see Atlas VERIFICATION_REPORT)

- The RustDesk fork build itself (Rust + Flutter toolchain, ~30 min).
- macOS first-run TCC grant (Screen Recording + Accessibility).
- Windows signing (awaits the cert / Azure Trusted Signing).
- Windows secure-desktop / UAC robustness.
- Two-machine NAT/firewall latency validation.
- AGPL counsel sign-off.
