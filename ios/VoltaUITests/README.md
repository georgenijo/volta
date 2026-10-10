# Demo screenshot contract

`ios/project.yml` conditionally includes `project.uitests.yml` when
`VOLTA_INCLUDE_UITESTS=true`. Both `ios-build.sh` and `screenshots.sh` enable
existing includes; direct XcodeGen callers must set the flags explicitly.
The include adds the shared `VoltaCI` scheme and leaves `Volta` intact.

## Frame worker: launch contract

`ScreenScreenshotTests` launches with **`-demo-mode YES`**. The app must honor
this argument before reading tokens or showing pairing, select populated
`MockDataSource()`, load its vehicle, and bypass the local app lock for that
synthetic launch. Normal launches retain the normal pairing and lock behavior.
Use an in-memory settings domain for UI test launches so Settings screenshots
always use default miles / °F / USD and never depend on a previous simulator
session. Do not persist demo flags, change real tokens, or contact a backend.

Launch-only demo settings are entirely in memory. Exiting the preview stays
isolated for that process; relaunch normally to restore saved pairing and lock.
Every demo entry clears widget snapshots and Live Activities; no publisher is
injected into demo screens, so mock refreshes never reach WidgetSync.

## Screen agents: accessibility identifiers

Place identifiers on the actual Button / NavigationLink / ScrollView (or
List/Form scroll container). A
`screen.*` marker should be a visible heading or other accessible leaf that
exists **after the demo content has loaded**. Do not put a marker on a SwiftUI
container that hides or propagates its identifier to all descendant controls.
Identifiers supplement, rather than replace, human-readable accessibility labels.

| Owner | Identifier | Element / behavior |
| --- | --- | --- |
| Shell (A) | `tab.dashboard` | Dashboard tab button |
| Shell (A) | `tab.charging` | Charging tab button |
| Shell (A) | `tab.drives` | Drives tab button |
| Shell (A) | `tab.idles` | Idles tab button |
| Shell (A) | `button.more` | Circular More button |
| Dashboard (A) | `button.controls` | Opens Controls sheet |
| More (C) | `button.settings` | Pushes Settings from More |
| Dashboard (A) | `screen.dashboard`, `scroll.dashboard` | Loaded heading and main scroll view |
| History (B) | `screen.charging`, `screen.drives`, `screen.idles` | Loaded list headings |
| History (B) | `row.drive.<id>`, `row.charge.<id>` | Entire tappable populated row; stable model ID suffix |
| History (B) | `screen.drive-detail`, `screen.charge-detail` | Loaded detail heading |
| More (C) | `screen.more`, `scroll.more` | Heading and main scroll view |
| More (C) | `row.more.<slug>` | More rows: `stats`, `battery-health`, `battery-climate`, `tires`, `maintenance`, `firmware`, `mileage`, `specs`, `charger-map`, `switch-vehicle` |
| History (B) | `button.drives.roadtrips`, `button.drives.heatmap` | Drives shortcut chips |
| Settings (C) | `screen.settings`, `scroll.settings` | Heading and main scroll view |
| Controls (A) | `screen.controls`, `scroll.controls` | Sheet heading and scroll view |
| Settings (C) | `button.account` | Pushes Account from Settings |
| Tesla | `button.teslaSignIn`, `button.teslaDisconnect`, `row.teslaStatus` | Sign in with Tesla (no-vehicle screen and Account) |

Demo lists must have at least one visible tappable drive row and charge row.
The tests use identifier prefixes, so they do not couple to mock IDs or text.
They wait for readiness and hittability instead of sleeping. Each of the eleven
tests starts a fresh app, so a missing detail screen does not prevent the other
tests from attaching their screenshots. Missing screens **fail**; there are no
silent skips or translated-label selectors.

## Run and compare

```sh
DEVELOPER_DIR=/Users/macbook/Applications-staging/Xcode.app/Contents/Developer \
  bash scripts/screenshots.sh
```

The script selects an available iOS 26+ iPhone, preferring iPhone 17 Pro on the
newest installed runtime. Set `SIMULATOR_UDID` or `IOS_DESTINATION` to override.
Use `RESULT_BUNDLE_PATH=build/screenshots-2.xcresult` for subsequent runs; existing
result bundles are preserved. Run `--help` for all options.

Named PNGs and the attachment manifest land in `docs/screens/latest/`:
`dashboard-map`, `dashboard-mid`, `dashboard-scrolled`, `charging`, `drives`,
`idles`, `more-top`, `more-bottom`, `settings-top`, `settings-bottom`,
`drive-detail`, `charge-detail`, `controls-top`, `controls-bottom`,
`tesla-no-vehicle`, `settings-account`. The no-vehicle capture launches with the
debug-only `-demoNoVehicles YES` argument.
Names are derived from XCTest attachments, with Xcode's UUID suffix removed.
PNG export also runs after failed UI tests; `screenshots.json` records the test
exit code. Treat failure images and partial exports as diagnostic evidence.
For `--export-only`, that field is `null` because no test process ran; consult
the xcresult for the original test outcome.
The script removes only PNGs listed in its prior `screenshots.json`; it preserves
unrelated files. Do not commit generated results or screenshots by default.
`docs/screens/latest/` is ignored by Git. Keep the required export destination
for comparison.

Native verification on iPhone 17 Pro / iOS 26.5 confirmed the dashboard swipe
scrolls the page rather than the map. Its second swipe can already be at the
bottom, so `dashboard-mid` and `dashboard-scrolled` may show the same content.

Compare these captures with the private Wattly reference screenshots. Charging/drives/idles captures
are populated demo screens, whereas the supplied history reference images are
empty states. This suite establishes navigation and screenshots; visual
comparison and empty-state acceptance remain the lead's integration checks.

CI builds test runners once, runs unit tests, then calls `--skip-build` to run
only the UI target. `--export-only build/screenshots.xcresult` can re-export an
existing result without launching the app.
