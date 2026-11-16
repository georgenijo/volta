import AppIntents

/// Siri phrases and Spotlight actions available without any setup. The system
/// allows ten; the remaining actions (charging, Sentry, honk, frunk, trunk) are
/// in the Shortcuts app.
struct VoltaShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .blue }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckBatteryIntent(),
            phrases: [
                "What’s my battery in \(.applicationName)",
                "Check my battery in \(.applicationName)",
                "How much battery does my car have in \(.applicationName)",
                "\(.applicationName) battery",
            ],
            shortTitle: "Battery",
            systemImageName: "battery.75percent")
        AppShortcut(
            intent: CheckRangeIntent(),
            phrases: [
                "What’s my range in \(.applicationName)",
                "How far can I drive with \(.applicationName)",
                "\(.applicationName) range",
            ],
            shortTitle: "Range",
            systemImageName: "gauge.with.dots.needle.67percent")
        AppShortcut(
            intent: CheckChargingIntent(),
            phrases: [
                "Is my car charging in \(.applicationName)",
                "How long until my car is charged in \(.applicationName)",
                "\(.applicationName) charging status",
            ],
            shortTitle: "Charging",
            systemImageName: "bolt.car")
        AppShortcut(
            intent: LocateVehicleIntent(),
            phrases: [
                "Where’s my car in \(.applicationName)",
                "Where is my car in \(.applicationName)",
                "Where did I park in \(.applicationName)",
            ],
            shortTitle: "Where’s My Car",
            systemImageName: "mappin.and.ellipse")
        AppShortcut(
            intent: CheckSecurityIntent(),
            phrases: [
                "Is my car locked in \(.applicationName)",
                "Is Sentry on in \(.applicationName)",
                "Check my car’s locks in \(.applicationName)",
            ],
            shortTitle: "Locks & Sentry",
            systemImageName: "lock.shield")
        AppShortcut(
            intent: LockVehicleIntent(),
            phrases: [
                "Lock my car with \(.applicationName)",
                "Lock my car in \(.applicationName)",
                "\(.applicationName) lock my car",
            ],
            shortTitle: "Lock",
            systemImageName: "lock.fill")
        AppShortcut(
            intent: UnlockVehicleIntent(),
            phrases: [
                "Unlock my car with \(.applicationName)",
                "Unlock my car in \(.applicationName)",
            ],
            shortTitle: "Unlock",
            systemImageName: "lock.open.fill")
        AppShortcut(
            intent: SetClimateIntent(),
            phrases: [
                "Turn \(\.$state) climate with \(.applicationName)",
                "Turn \(\.$state) my car’s climate with \(.applicationName)",
                "Turn \(\.$state) climate in \(.applicationName)",
                "Precondition my car with \(.applicationName)",
            ],
            shortTitle: "Climate",
            systemImageName: "fan")
        AppShortcut(
            intent: SetChargePortIntent(),
            phrases: [
                "\(\.$command) my charge port with \(.applicationName)",
                "\(\.$command) the charge port with \(.applicationName)",
                "\(\.$command) the charge port in \(.applicationName)",
            ],
            shortTitle: "Charge Port",
            systemImageName: "powerplug")
        AppShortcut(
            intent: FlashLightsIntent(),
            phrases: [
                "Flash my car’s lights with \(.applicationName)",
                "Flash my lights with \(.applicationName)",
            ],
            shortTitle: "Flash Lights",
            systemImageName: "headlight.high.beam.fill")
    }
}
