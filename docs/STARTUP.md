# Startup benchmark

The dashboard's first useful state is fresh vehicle status: battery, range,
location and controls. History has independent loading and error states. A slow
timeline or activity summary must not delay this state. History requests still
run concurrently and fill their sections as they complete; this does not make
the server queries themselves faster.

The first dashboard consumes the vehicle list that `AppModel` loads at startup,
avoiding a second `/vehicles` request. When the shell mounts before that list
arrives (see below), the dashboard awaits the same request. This handoff is used
once and discarded on vehicle selection, account changes, or backgrounding.
Later dashboard mounts and refreshes fetch a current list. Fresh status can
appear while that list is pending; a list failure does not discard successful history.

## Saved dashboard and launch requests

After each load with fresh status, the dashboard saves the vehicles, that
status, and the history sections that same load fetched (48-hour timeline,
summaries) to one file in Application Support: `.completeFileProtection`,
excluded from backups, and keyed to the backend (server address plus a digest
of the device token) and vehicle. A section that failed or was cancelled is left
out rather than saved again under the new date. On the next launch `AppModel`
reads the file before the first frame, so the tab shell and the saved dashboard
appear in that frame.

- The caption reads "Saved 2 hr. ago · car last seen …", with a small
  refreshing indicator, until fresh status replaces it. A failed refresh keeps
  it with the usual "Couldn't refresh" banner, and becoming active retries
  once that attempt is over 10 s old. Each history section keeps its saved
  data, marked "Saved 2 hr. ago", until this load replaces it; one whose load
  fails stays marked. History, saving and widget publication never wait for
  the vehicle list.
- No command is based on saved status: while `ControlsModel` holds it, no
  control is enabled, `send` refuses, and Controls says "Showing saved data ·
  controls unlock after a refresh". Saved status also keeps no location
  time, so HomeLink never offers itself. Colours stay as they are; the
  caption and a small refreshing indicator carry the provenance. The live
  charging sheet says "SAVED DATA", and names a failed refresh.
- Saved data leaves `lastLoadedAt` nil, so becoming active while it shows does
  not start a second load; nor does it while sections are still loading.
- Saved data never reaches widgets or Live Activities. Yesterday's saved
  "Today" totals are hidden by the existing reporting-day rule.
- Unpairing, demo mode and a revoked token delete the file before `remove()`
  returns, and a write queued before that cannot recreate it. A load that
  outlives its pairing cannot write it. Write, removal and backup-exclusion
  failures are logged by error domain and code.
- Nothing is read or sent while app lock is on; unlocking restores it.

A restored pairing sends `/status` (only when a saved dashboard will mount the
shell) and then `/vehicles` from `AppModel.init`, in detached tasks, so neither
waits for the first frame to be laid out. The vehicle load exists before any
view's task runs: the root view and the first dashboard join it in either
order, and a load that already finished is not repeated. The first dashboard
awaits that status, with its widget-ordering token taken just before it was
sent. A launch in an iOS prewarm sends nothing, because the process may then be
suspended for hours. The dashboard drops a launch status sent more than 5 s
before it mounts, and retries once a launch status that got no answer.

History (timeline and the three summaries) is sent at launch with status, under
the same rules. Over HTTP/2, which the live API speaks, the requests share one
connection: in the November 2026 runs below, every section arrived 77–209 ms
sooner and fresh status was not slower. Over HTTP/1.1 each extra request opens
its own TLS connection, and an earlier HTTP/1.1 run measured status *slower*
(1.55 → 2.11 s at 150 ms RTT) with history sent early; revisit this if the
server ever stops negotiating HTTP/2.

### November 2026 results

Release build on the dedicated simulator, ms after `AppModel` starts, median
(range) of ten launches: two interleaved rounds of five per build after a
warm-up, host load average 10–35 for all but one run. A is `main` with only this
harness; B is the branch with status alone sent early; C, the branch as shipped,
also sends history early. Milestones are logged at the next display refresh.

| HTTP/2, server timings | first frame | saved data visible | fresh status visible | all sections visible |
|---|---|---|---|---|
| A | 288 (spinner) | — | 1703 | 2293 |
| B | 1567 | 1643 | 1670 | 2168 |
| C | 1516 | 1516 | 1516 | 2091 |

| HTTP/2, +150 ms RTT | first frame | saved data visible | fresh status visible | all sections visible |
|---|---|---|---|---|
| A | 324 (spinner) | — | 1970 | 2776 |
| B | 1710 | 1710 | 1710 | 2452 |
| C | 1522 | 1522 | 1522 | 2243 |

| HTTP/1.1, +150 ms RTT | first frame | saved data visible | fresh status visible | all sections visible |
|---|---|---|---|---|
| A | 290 (spinner) | — | 1864 | 3066 |
| B | 1401 | 1401 | 1401 | 2265 |

A's first frame is the "Loading vehicles…" spinner; its tab shell follows at
1450–1694 ms. B and C draw their first frame later, but it already has the
dashboard, and fresh status usually lands before that frame is committed. The
remaining cost is the first layout of the redesigned dashboard, about 1.2 s
after `AppModel` here in both A's shell and the branch's first frame.

`DashboardModelTests` suspends history requests with explicit gates to verify
that status and faster sections become usable while slower work remains pending.
It also covers overlapping loads, cancellation and partial failures. Widget
publication remains once per completed refresh, ordered by its status token.

## Repeatable simulator measurement

Use a dedicated simulator with synthetic pairing. Never run these benchmarks
against an owner's account. `scripts/startup-fixture.py` binds to IPv4 loopback
only and supplies synthetic API responses through the real `APIDataSource`,
JSON decoder and SwiftUI screens. It neither logs nor requires real credentials.
Use `https://127.0.0.1:9443`, including that IP in the test certificate's SAN.

1. Generate a temporary localhost development certificate and trust its root
   **only on the benchmark simulator** with
   `xcrun simctl keychain <simulator-id> add-root-cert <certificate>`.
   Keep the key and certificate outside this repository and evidence bundles.
2. Start the fixture:

   ```sh
   python3 scripts/startup-fixture.py --cert /tmp/localhost.crt \
     --key /tmp/localhost.key --profile observed-server --log /tmp/startup.jsonl
   ```

3. Generate the project and build the app and test runners. Preserve normal
   simulator signing: disabling signing breaks Keychain pairing.

   ```sh
   VOLTA_INCLUDE_WIDGETS=true VOLTA_INCLUDE_UITESTS=true \
     xcodegen generate --spec ios/project.yml -q
   xcodebuild build-for-testing -project ios/Volta.xcodeproj -scheme VoltaCI \
     -configuration Release -destination 'platform=iOS Simulator,id=<simulator-id>' \
     -derivedDataPath /tmp/volta-benchmark \
     CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES ENABLE_TESTABILITY=YES
   ```

4. Pair the fresh simulator once using `StartupBenchmarkTests/testPairFixture`.
   Then run `testDashboardReadiness` and `testFirstFramePerformance` separately
   from normal UI screenshot tests, which deliberately switch to demo mode.

   ```sh
   TEST_RUNNER_VOLTA_STARTUP_BENCHMARK=1 xcodebuild test-without-building \
     -project ios/Volta.xcodeproj -scheme VoltaCI -configuration Release \
     -destination 'platform=iOS Simulator,id=<simulator-id>' \
     -derivedDataPath /tmp/volta-benchmark -parallel-testing-enabled NO \
     -only-testing:VoltaUITests/StartupBenchmarkTests/testDashboardReadiness \
     -resultBundlePath /tmp/startup-results.xcresult
   ```

   Substitute the desired test method in `-only-testing`. These tests skip
   unless explicitly enabled with the environment variable above.

5. Repeat on the original revision and the optimized revision with the identical
   test file, fixture, simulator, build configuration and latency profile.
   Keep separate build products and result bundles. Do not run builds or other
   CPU-heavy work concurrently with timings. Export attachments with
   `xcrun xcresulttool export attachments --path <result> --output-path <folder>`.

`scripts/startup-bench.sh <simulator-id> <derived-data> <profile> <out-dir> <ca-cert>`
runs the readiness test while streaming the app's `startup` log milestones
(`StartupTrace`: `appModel`, `firstFrame`, `shell`, `vehicles`, `cachedStatus`,
`status`, `sections`, in milliseconds since process start), then prints each
launch and the medians. It also reports each milestone relative to `appModel`:
the time before it is mostly the simulator's dyld and Swift conformance setup,
which swings with host load. Every milestone after `appModel` is logged at the
first display refresh after it was reached, when the frame showing it has been
committed: `cachedStatus` is saved data on screen (not logged when fresh
status replaced it before any frame), `status` fresh status on screen, and
`sections` every history section on screen. Each readiness launch
stays open four seconds so history milestones are recorded.

The live API speaks HTTP/2, where parallel requests share one connection.
`scripts/startup-fixture-h2.py` puts the fixture behind a loopback-only HTTP/2
front end (it needs `pip install h2` in a scratch virtual env). It charges the
two connection round trips once per client connection, and the fixture, run
with `--plain` on another loopback port, charges one per request. Forwarding
adds roughly 50–100 ms of local overhead per request; compare HTTP/2 runs with
each other, not with HTTP/1.1 runs.

The readiness test retains one warm-up and five measured fresh-process launches
in `startup-samples.json`; compare medians and ranges excluding trial zero.
Its clock includes `XCUIApplication.launch()` and accessibility polling overhead.
`screen.dashboard` means status is present, not that map tiles or all history
have finished. These are process launches on a booted simulator with warm OS
caches, not cold-device launches or a prediction of physical iPhone performance.
First-frame metrics are a separate XCTest measurement; a successful test with
no exported metric is not a timing result.

The `observed-server` profile replays a small server-only timing sample (20 ms
vehicles, 29 ms status, 15 ms timeline, 4.189 s summaries). It excludes transit
and is not a general production-latency claim. `server-2026-11` uses the November 2026 live route timings (status 10 ms,
summaries 270 ms / 320 ms / 1.16 s). `server-2026-11-rtt150` adds a simulated
150 ms round trip, roughly a phone on Tailscale or cellular: two round trips per
new connection (TCP and TLS 1.3) and one per request. The fixture speaks
HTTP/1.1, so it charges every parallel request a new connection; an HTTP/2
server multiplexes them over one. `instant` isolates local work;
`slow-history` stresses delayed summaries; `history-failure` verifies that
status remains usable when history fails. Change profiles between runs:

```sh
curl --cacert /tmp/localhost.crt https://127.0.0.1:9443/__benchmark/profile \
  -H 'Content-Type: application/json' -d '{"profile":"slow-history"}'
```
