# App frame integration

The app injects `AppModel` and `UserSettings` as observable environments, plus
`\.dataSource`, `\.vehicleID`, and `\.units`. Screens use the three value
keys to load vehicle data; Settings may use `@Environment(AppModel.self)`
and `@Bindable` for writable preferences.

- `model.units` / `model.settings.units`: persisted `UnitPreferences`.
- `model.selectedVehicleID`: writable persisted selection, from `model.vehicles`;
  `model.select(_:)` for a vehicle from a screen's own, possibly newer list;
  `model.vehicles` / `model.selectedVehicle`: loaded vehicle choices.
- `model.appLockEnabled`: writable binding that authenticates before enabling.
  Prefer `await model.setAppLockEnabled(...)` in explicit actions. Do not bind
  Security directly to `settings.appLockEnabled`. The lock flag persists. Face ID or system
  passcode unlocks; background locks and inactive scenes conceal history without destroying
  navigation. The lock screen offers credential-removing recovery if system
  authentication is unavailable.
- `model.isDemoMode`: current data source mode.
- `model.tryDemoMode(empty: false)`: synthetic Friday history;
  `empty: true` retains the vehicle/status but empties history collections.
- `model.unpair()`: local disconnect and Keychain token removal.
- `await model.revokeAndUnpair()`: revoke `/v1/me` before local disconnect.
  `model.errorMessage` exposes recoverable connection/revocation errors.
- `model.settings.serverURL`: remembered pairing address. Pair again through
  `model.pair(...)` to change the authenticated endpoint; editing the saved
  URL alone does not rebuild the existing API client.

`TemporaryMainShell.swift` is a temporary frame-only screen. Delete that file
when `Features/Shell/MainShell.swift` is integrated; the real type name is
`MainShell()` with no constructor arguments. The root waits for a valid
vehicle before presenting it and resets shell identity when vehicle or mode
changes.

Shared formatting uses `UnitPreferences.Distance` (`miles`, `kilometers`),
`UnitPreferences.Temperature` (`fahrenheit`, `celsius`), and a currency code.
`distanceValue(km:)`, `temperatureValue(celsius:)`, and
`efficiencyValue(whPerKm:)` return converted numbers for charts.
`formatDistance`, `formatTemperature`, `formatEfficiency`, `formatMoney`
return display strings. `VoltaFormat` additionally supplies `energy`,
`duration(minutes:)`, `relativeDate`, and `number`. Unknown optional values
format as an em dash, preserving the API's null-versus-zero distinction.

The only addition to existing API model shapes is `HealthResponse` and its
nested `TeslaMateHealth`. Drive/charge detail JSON remains flattened as in
`docs/API.md`; model storage still exposes `.summary`.

Run `scripts/ios-build.sh` with Xcode selected (or `DEVELOPER_DIR` set).
Simulator builds use normal ad-hoc signing so Keychain integration is valid.
Override the selected simulator with `VOLTA_SIMULATOR_ID` if needed.

The app uses automatic signing with the paid team set in the untracked
`ios/Config/Signing.local.xcconfig` (copy `Signing.local.xcconfig.example`), and the App Group
`group.com.georgenijo.volta`. Widgets and Live Activities are fed through
that group by `WidgetSync` (`AppModel.surfaces`); see
`ios/VoltaWidgets/README.md` for the contexts and the demo-mode policy. AppIcon, AccentColor and
LaunchBackground are wired to the Brand worker's asset catalog.

Launch with `-demo-mode YES` for populated synthetic data without touching
Keychain or pairing. This launch override does not persist demo-mode selection or vehicle selection.
`model.isLaunchDemo` identifies it. Units and security preferences use fresh in-memory defaults for that process.
Unpair/revoke/recovery actions exit this launch demo but keep the process
isolated: relaunch normally to restore saved pairing and lock. Label that action "Exit launch
demo" when this flag is true.

`ios/project.yml` includes `project.widgets.yml` and `project.uitests.yml` behind
XcodeGen's enable flags. `scripts/ios-build.sh` sets `VOLTA_INCLUDE_WIDGETS` and
`VOLTA_INCLUDE_UITESTS` from file existence automatically. For a direct XcodeGen
call, export the corresponding flag as `true` when its spec is present. Missing
optional specs do not block the core app project.
