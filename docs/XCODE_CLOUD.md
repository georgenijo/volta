# Volta → internal TestFlight

This repository prepares an iOS Release archive, including VoltaWidgets. It does
not configure an Apple workflow or prove a Cloud upload. The intended workflow
matches CoachOS/HomeOS: archive on relevant `main` changes, then internal TestFlight.

## Apple workflow (one-time owner setup)

- Product/project: `ios/Volta.xcodeproj`, shared scheme `Volta`.
- Trigger: branch changes on `main`, files matching `ios/**` and
  `scripts/ios-build.sh` (the local generation contract).
- Environment: pin Xcode **26.6** (local build `17F113`), with the iOS 26 SDK.
  Upgrade deliberately after validation.
- Action: Archive, iOS, configuration `Release`. No simulator, test or screenshot
  actions are needed for this delivery workflow.
- Post-action: TestFlight Internal Testing, group `Internal` (owner creates or
  selects it in App Store Connect).
- Automatic signing: select the owner's Apple team; app `com.georgenijo.volta`, embedded widget
  `com.georgenijo.volta.widgets`, App Group `group.com.georgenijo.volta` on both.
  The owner must confirm identifiers, capabilities and provisioning in Apple.
  No certificates, credentials or access grants are stored by these scripts.

Generate locally with the intended team before opening Xcode to discover the
archivable product (`APPLE_TEAM_ID` is supplied locally, not committed):

```sh
CI_PRIMARY_REPOSITORY_PATH="$PWD" CI_BUILD_NUMBER=1 CI_TEAM_ID="$APPLE_TEAM_ID" \
  ios/ci_scripts/ci_post_clone.sh
xcodebuild -project ios/Volta.xcodeproj -describeAllArchivableProducts -json
```

The project and shared scheme remain generated/ignored. Select this generated
project during initial Xcode Cloud setup; `ios/ci_scripts/ci_post_clone.sh` sits
beside it, as [Apple's script placement rules](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts)
require. After cloning, the executable script downloads XcodeGen **2.46.0** from
its public upstream release, verifies the pinned SHA-256 and generates the project
with widgets and mandatory AppSide sources enabled. This uses HomeOS's prebuilt
download approach, avoiding its observed Homebrew DNS failure; it keeps Volta's
existing include-flag contract and uses no additional dependency or brew fallback.
The first live Cloud archive must confirm generated-project discovery works.

Both targets inherit marketing version `1.0` and local build number `1`. Post-clone
uses [Apple's `CI_BUILD_NUMBER`](https://developer.apple.com/documentation/xcode/environment-variable-reference)
and `CI_TEAM_ID` through a temporary XcodeGen settings overlay, so app and widget
metadata and signing team match. Cloud supplies the team selected during setup;
the public repo's privacy checks prohibit committing personal signing team IDs.
Use Cloud's integer build sequence; if an existing upload would collide, the owner
must [set the next Cloud build number](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds).
Commit the app plist's version placeholders, but not the generated project,
temporary Cloud settings or `Signing.local.xcconfig`.

## Local check and live acceptance

```sh
CI_PRIMARY_REPOSITORY_PATH="$PWD" CI_BUILD_NUMBER=42 CI_TEAM_ID="$APPLE_TEAM_ID" \
  ios/ci_scripts/ci_post_clone.sh
xcodebuild -project ios/Volta.xcodeproj -scheme Volta -configuration Release \
  -destination 'generic/platform=iOS' -archivePath ios/build/Volta.xcarchive \
  -derivedDataPath ios/build/CloudDerivedData CODE_SIGNING_ALLOWED=NO archive
```

Inspect the archive's `Volta.app/Info.plist` and embedded
`PlugIns/VoltaWidgets.appex/Info.plist` for bundle IDs and matching versions. An
unsigned archive proves compilation and packaging, not Apple signing or delivery.

Source inspection found Apple `URLSession` HTTPS, Security keychain storage and
LocalAuthentication, with no bundled third-party or custom crypto implementation.
No export-compliance declaration is added here. The owner must resolve export
compliance in App Store Connect using [Apple's encryption guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations).

Live acceptance remains: Cloud recognizes post-clone, signs both targets, archives
and uploads successfully; App Store Connect processes the build; TestFlight shows
it ready in `Internal`; the owner installs and opens the app on an iPhone. Local
checks make no Tesla calls and establish none of these live results.
