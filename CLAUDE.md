# CLAUDE.md

This repo is **`cloudflare_realtime`**, an unofficial Flutter client for the Cloudflare Realtime SFU, built on `flutter_webrtc`. It is **public** and will be published to pub.dev. Its first consumer is the buildIt.Social app, which is private and developed separately.

## Read first

- [docs/design.md](docs/design.md): the architecture, the broker contract and its security rules, and the open questions.
- [docs/cloudflare-sfu.md](docs/cloudflare-sfu.md): the SFU API, its rules and its sources.
- [docs/roadmap.md](docs/roadmap.md): milestones and the **week-6 consumer checkpoint**. Prioritize what that checkpoint needs.

## Rules

- **This repo is public.**
  - Never commit secrets: Cloudflare App Secrets, TURN keys, tokens, `.env` files.
  - Never print secret values in output, logs, tests or docs. Integration tests read credentials from the environment.
  - Don't put private details of any consuming app here: its infrastructure, costs, customers or security history.
- **The App Secret never goes in client code.** All SFU calls go through the broker ([design.md §5](docs/design.md#5-broker-contract)). Keep the broker's security rules (auth, room check, session binding, same-room pulls) in any reference broker.
- **The core package has no backend SDK dependencies.** Signaling is an interface. Adapters such as Supabase live elsewhere.
- **Licensing:**
  - Porting from partytracks (ISC) is fine; keep [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) current.
  - **Don't copy AGPL/GPL code** (for example, RustDesk).
  - Don't copy LiveKit SDK code. Using similar concepts is fine.
- Keep `publish_to: none` until milestone M8.
- When a design decision changes, update `docs/design.md` (and the roadmap if the scope moves) in the same change.

## Tooling

- **Flutter:** 3.47.3 / Dart 3.13.3.
- **Before committing:** `flutter analyze`, `dart format .` and `flutter test`.
- **CI is off until launch:** GitHub Actions is disabled on the repo (to save CI minutes); `.github/workflows/ci.yml` is kept for later. Don't trigger `workflow_dispatch` runs. Run what CI ran locally before pushing:
  - `dart format --output=none --set-exit-if-changed .`, `flutter analyze`, `flutter test`, and `flutter test` in `example/`;
  - `gitleaks git --log-opts="origin/main..HEAD"` on the commits being pushed (the pre-commit hook covers each commit);
  - when `broker/` or `tools/dev-server/` changed: `npm ci`, `npm run typecheck` and `npm test` in that folder.
- **Pre-commit hook:** enable it once per clone with `git config core.hooksPath .githooks`. It runs `gitleaks git --staged`.

## This machine (Windows 11)

- **PowerShell blocks `.ps1` scripts.** Use Git Bash, or call `.exe`/`.cmd` directly.
- **`gh`** is at `C:\Program Files\GitHub CLI\gh.exe`, logged in as `kammcs`.
- **`gitleaks`** is installed through winget (`%LOCALAPPDATA%\Microsoft\WinGet\Links\gitleaks.exe`).
- **VS Build Tools 17.12 is too old for Windows builds, and lacks ATL.** You need VS 2022 17.14+ with the "C++ ATL" component.
- **Git identity:** `kammcs <85201048+kammcs@users.noreply.github.com>`.
