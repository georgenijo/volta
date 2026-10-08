# Volta CI

`server.yml` runs on PRs touching `server/**`, `deploy/**`, or that workflow,
on Ubuntu 24.04 with Bun 1.4.1 and a disposable Postgres 17 service. It runs frozen-lockfile
install, `bun run typecheck`, then `bun test`. Tests must create and seed the
TeslaMate fixture rows in the disposable database; CI never connects to
George's TeslaMate instance. The workflow first restores the backend worker's
`test/teslamate-v4.3.0.sql` schema and applies `deploy/bootstrap.sql` (omitting
interactive password prompts) with its `auth-schema.sql`, `auth-grants.sql`, and `privilege-checks.sql`. Tests match the
backend's `TEST_DATABASE_URL` contract: isolated localhost `volta_test`, plus
`TESLAMATE_DATABASE_URL` for the restricted reader and `AUTH_DATABASE_URL` for
the auth role. Fixed synthetic passwords apply only to the disposable service.
Tests use the owner role to seed/truncate fixtures and exercise API behavior
through the production reader/auth grants.

`ios.yml` runs on PRs touching `ios/**`, `scripts/screenshots.sh`, or that
workflow. It uses the standard **`macos-26`** image and explicitly selects Xcode
26.6. GitHub's [runner catalog](https://github.com/actions/runner-images) and
[macOS 26 ARM64 image manifest](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
confirmed this label, Xcode path, and iOS 26 simulators on 2026-10-07. If the
image retires Xcode 26.6, update the developer path and cache version together.
Simulator selection checks installed devices instead of assuming a name/OS
combination. No signing secrets are needed.
Simulator builds retain Xcode's default ad hoc signing so the app/test host
can exercise Keychain with its normal entitlements.
An Ubuntu preflight fails explicitly if `ios/project.yml` has not landed,
avoiding billed macOS setup for a branch missing the frame project.

The frame project already includes `project.uitests.yml` conditionally.
Generation sets `VOLTA_INCLUDE_UITESTS=true` and enables widgets when present.
See [the UI harness contract](../ios/VoltaUITests/README.md) for demo launch and
screen identifiers. CI generates with XcodeGen, builds app and test runners
once under `VoltaCI`, runs `VoltaTests`, then runs `VoltaUITests` using the same
build products. UI failures remain failures even if partial PNGs export.
Screenshots, xcresults, and capture logs upload as an Actions artifact with a
seven-day retention period. The repo is public, so artifacts are readable by
anyone signed in to GitHub; they contain demo data only.

## Cost budget

Budget **8–12 macOS wall-clock minutes per run**, or **80–120 minutes using the
requested 10× planning multiplier**. This is an estimate, not a measured Volta
run. The job has a 25-minute execution limit (250 minutes at that multiplier;
upload/cleanup and rounding may add time). Ubuntu server runs should take
roughly 1–3 minutes, also unmeasured. Revisit the estimates after integrated CI.

GitHub currently publishes a standard macOS rate of $0.062/minute and Linux
2-core rate of $0.006/minute, approximately 10×. At published overage rates,
8–12 macOS minutes is about $0.50–$0.74, excluding storage and taxes; **do not
multiply that dollar amount by 10 again**. Plan allowances and actual charges
come from the account billing dashboard. See [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).

Cost controls: PR path filters, no duplicate push-triggered builds, one iPhone
without a matrix, cancel superseded runs per PR, bounded timeouts, cached Bun
downloads / Xcode compiler caches / Swift package downloads, shared test build
products, disabled parallel simulator cloning, and short artifact retention.
Only reusable compiler caches and package downloads are cached, keeping cache
storage smaller than a complete DerivedData snapshot. There are no third-party
Swift packages currently, but SourcePackages is ready for future additions.
Compiler caching is explicitly enabled for builds. Cache keys stay stable for
the toolchain and project/package configuration. Caches improve repeat runs
within the same PR; new PRs normally start cold because main does not seed
them. This deliberately avoids a second billed macOS run on merge.
Workflow dispatch is available for intentional manual verification.

Because these workflows use path filters, do not require them unconditionally
on documentation-only PRs: GitHub may leave a filtered required workflow
pending. Branch-protection settings are owned by the lead; this change does
not alter them.

## Privacy

This repo is public; vehicle data, hostnames, and personal artifacts are not.
`privacy.yml` runs `scripts/privacy-check.sh` on every PR and push to `main`.
It rejects real tailnet hostnames (use `volta-node.example.ts.net`), Tailscale
addresses outside the `100.64.0.0/24` test range, a hard-coded
`DEVELOPMENT_TEAM`, and tracked files under `docs/reference/` or `docs/screens/`.
Locally the same script also rejects every string in a denylist kept outside
the repo (`~/.config/volta/private-denylist`). Enable the hooks in every clone
with `git config core.hooksPath .githooks`: `pre-commit` scans the staged tree
and requires a `users.noreply.github.com` author email, and `pre-push` rescans
every outgoing commit. Fixtures use synthetic Bay Area places only.

Personal values live outside Git: the signing team in
`ios/Config/Signing.local.xcconfig`, deploy hostnames in each node's `.env`,
and Wattly reference and device screenshots in the private `volta-private`
repo. Fixtures use synthetic Palo Alto–area places and fake VINs.
