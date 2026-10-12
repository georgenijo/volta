# Agent guide

Volta is a personal iOS Tesla analytics app with a Wattly-style UI. Its data
comes from the owner's own TeslaMate and Fleet Telemetry backend. It is never
published to the App Store; builds go to TestFlight Internal only.

Before any deployment, backend, signing, or TestFlight work, read the private
operations notes at `~/.config/volta/AGENTS.private.md` on the machine you are
on. Never copy anything from that file into this repository.

## Layout

- `ios/` — SwiftUI app and widgets (XcodeGen spec `ios/project.yml`)
- `server/` — volta-api (Bun + Hono), reads TeslaMate Postgres read-only
- `commander/`, `ingestion/`, `deploy/` — vehicle commands, telemetry ingest, deployment
- `docs/SPEC.md`, `docs/API.md` — product spec and API contract; `docs/PARITY.md` — Wattly parity notes

## This repository is public

- Use only synthetic data: Bay Area coordinates, `telemetry.example.com`,
  `192.0.2.x` addresses. Never commit real names, addresses, coordinates,
  hostnames, IP addresses, team IDs, emails, VINs, or screenshots
  (`docs/screens/latest/` is generated output).
- Commit as `georgenijo <25929278+georgenijo@users.noreply.github.com>`, set in
  the clone's local git config.
- Install the privacy hooks with `bash scripts/install-hooks.sh`. They also read
  `~/.config/volta/private-denylist`. Never bypass them with `--no-verify`.
- Never push history from any other Volta repository here.

## Workflow

- Work on a branch and open a PR against `main`.
- Logic changes need one independent cross-family review before merge
  (Claude-written → `gpt-6-astra`, GPT-written → Claude Opus). UI-only polish does not.
- Run local tests during fix rounds; rely on CI once, on the final head.
- Never merge over failing or pending checks.
- Merge by fast-forwarding `main` locally and pushing. Never use GitHub's merge
  button: its merge commits fail the privacy hook.
- Each push to `main` that touches `ios/` starts an Xcode Cloud build to
  TestFlight. Combine parallel work into one merge where practical.

## Commands

```sh
# Server tests (local Postgres; set PG_BIN when Homebrew postgresql@17 is absent,
# for example PG_BIN=/usr/lib/postgresql/18/bin)
cd server && bun install && bun run test:local && bun run typecheck

# iOS (macOS with Xcode)
VOLTA_INCLUDE_WIDGETS=true VOLTA_INCLUDE_UITESTS=true xcodegen generate --spec ios/project.yml -q
xcodebuild test -project ios/Volta.xcodeproj -scheme VoltaCI -destination 'platform=iOS Simulator,name=<iPhone>'
```

## Data handling

- Never send addresses or coordinates to Apple geocoding (`CLGeocoder`,
  `MKLocalSearch`, `MKDirections`) or any third-party service, including map matching.
- Never print credentials, secrets, or VINs. Mask VINs in output with
  `sed -E "s/[A-HJ-NPR-Z0-9]{17}/<VIN>/g"`.
