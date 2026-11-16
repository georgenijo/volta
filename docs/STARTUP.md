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

After each load with fresh status, the dashboard saves what it shows (vehicles,
status, 48-hour timeline, summaries) to one file in Application Support:
`.completeFileProtection`, excluded from backups, and keyed to the backend
(server address plus a digest of the device token) and vehicle. On the next
launch `AppModel` reads it before the first frame, so the tab shell and the
saved dashboard appear in that frame. The status is labelled "Saved data from …"
until fresh status replaces it; a failed refresh keeps it with the usual
"Couldn't refresh" banner. Saved data never reaches widgets or Live Activities.
Yesterday's saved "Today" totals are hidden by the existing reporting-day rule.
Unpairing, demo mode and a revoked token delete the file, and a load that
outlives its pairing cannot write it. Nothing is read or sent while app lock is
on; unlocking restores it.

A restored pairing sends `/status` (only when a saved dashboard will mount the
shell) and then `/vehicles` from `AppModel.init`, in detached tasks, so neither
waits for the first frame to be laid out. The first dashboard awaits that
status, with its widget-ordering token taken just before it was sent. History
is not sent early: over HTTP/1.1 every extra launch request opens its own TLS
connection and delayed status.

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
which swings with host load. `firstFrame` is the first display refresh after the
root view appears. Each readiness launch now stays open four seconds so history
milestones are recorded.

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
