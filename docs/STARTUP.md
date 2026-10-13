# Startup benchmark

The dashboard's first useful state is fresh vehicle status: battery, range,
location and controls. History has independent loading and error states. A slow
timeline or activity summary must not delay this state. History requests still
run concurrently and fill their sections as they complete; this does not make
the server queries themselves faster.

The first dashboard consumes the vehicle list that `AppModel` just loaded,
avoiding a second `/vehicles` request at startup. This handoff is used once and
discarded on vehicle selection, account changes, or backgrounding. Later
dashboard mounts and refreshes fetch a current list. Fresh status can appear
while that list is pending; a list failure does not discard successful history.

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
and is not a general production-latency claim. `instant` isolates local work;
`slow-history` stresses delayed summaries; `history-failure` verifies that
status remains usable when history fails. Change profiles between runs:

```sh
curl --cacert /tmp/localhost.crt https://127.0.0.1:9443/__benchmark/profile \
  -H 'Content-Type: application/json' -d '{"profile":"slow-history"}'
```
