import Foundation

// Compiled into BOTH the app (Siri and Shortcuts answers) and the widget
// extension (Control Center and Lock Screen controls), so a spoken answer and
// a control always describe the same snapshot the same way. Foundation only.
//
// Rules: a value the snapshot does not have is "unknown", never zero or a
// guess. Location is the snapshot's place name only; coordinates never appear.
// Every answer says how old the reading is.

/// Words for one snapshot at one moment.
struct VehicleReadout: Sendable {
    let snapshot: WidgetSnapshot
    let now: Date

    init(_ snapshot: WidgetSnapshot, now: Date = .now) {
        self.snapshot = snapshot
        self.now = now
    }

    var name: String {
        let trimmed = snapshot.vehicleName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Your car" : trimmed
    }
    private var possessive: String { name.hasSuffix("s") ? "\(name)’" : "\(name)’s" }
    private var miles: Bool { snapshot.distanceUnit == .miles }
    var isStale: Bool { snapshot.isStale(at: now) }

    // MARK: Age

    /// "just now", "4 minutes ago", "3 hours ago".
    var age: String {
        Self.relative(snapshot.age(at: now))
    }

    private static func relative(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: "en_US")
        return formatter.localizedString(fromTimeInterval: -seconds)
    }

    /// Ends every spoken answer; stale readings say so plainly.
    var ageSentence: String {
        isStale ? "This reading is from \(age), so it may be out of date." : "Updated \(age)."
    }

    /// "45m", "3h", "2d": compact age for controls.
    var shortAge: String {
        let minutes = max(0, Int(snapshot.age(at: now) / 60))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 48 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }

    // MARK: Values

    /// "72%". The snapshot always records a battery level.
    var batteryPercent: String { "\(snapshot.batteryLevel)%" }

    /// Range in the user's unit, spelled out for speech: "204 miles".
    var spokenRange: String? {
        guard let km = snapshot.rangeKm, km.isFinite, km >= 0 else { return nil }
        let value = Int((miles ? km / 1.609344 : km).rounded())
        let unit = miles ? (value == 1 ? "mile" : "miles") : (value == 1 ? "kilometer" : "kilometers")
        return "\(value.formatted()) \(unit)"
    }

    /// Range for compact UI: "204 mi", or nil when unknown.
    var shortRange: String? {
        guard let km = snapshot.rangeKm, km.isFinite, km >= 0 else { return nil }
        return "\(Int((miles ? km / 1.609344 : km).rounded()).formatted()) \(miles ? "mi" : "km")"
    }

    /// "estimated" or "rated", whichever `rangeKm` used.
    var rangeKind: String { snapshot.estRangeKm != nil ? "estimated" : "rated" }

    /// Charging time remaining for speech: "1 hour, 5 minutes"; nil when unknown.
    var spokenTimeRemaining: String? {
        guard let minutes = snapshot.minutesToFull, minutes > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .full
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        formatter.calendar = calendar
        return formatter.string(from: TimeInterval(minutes * 60))
    }

    /// "1h 5m" / "45m"; nil when unknown.
    var shortTimeRemaining: String? {
        guard let minutes = snapshot.minutesToFull, minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// The saved place the car is at, or nil. Never an address or
    /// coordinates: only `savedPlace` is read, not the widgets' `placeName`.
    var place: String? {
        guard let raw = snapshot.savedPlace?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    /// Whether the snapshot knows where the car is (it may not be at a saved place).
    var hasLocation: Bool { snapshot.savedPlace != nil }

    /// How old the position is; nil when unknown. Battery and charging
    /// updates advance `updatedAt` without moving the position, so the
    /// location answer never uses the overall age.
    var locationAge: String? {
        snapshot.savedPlace?.recordedAt.map { Self.relative(max(0, now.timeIntervalSince($0))) }
    }

    var locationIsStale: Bool {
        guard let recordedAt = snapshot.savedPlace?.recordedAt else { return false }
        return now.timeIntervalSince(recordedAt) >= WidgetSnapshot.staleAfter
    }

    /// Ends the location answer.
    var locationAgeSentence: String {
        guard hasLocation else { return "" }
        guard let locationAge else { return "The location’s age is unknown." }
        return locationIsStale ? "This location is from \(locationAge), so it may be out of date." : "Located \(locationAge)."
    }

    /// Big value on the location snippet.
    var locationTitle: String {
        place ?? (hasLocation ? "Not at a saved place" : VehicleReadoutUnknown.value)
    }

    /// Footer on the location snippet.
    var locationFooter: String {
        guard hasLocation else { return "Location unknown" }
        guard let locationAge else { return "Location age unknown" }
        return locationIsStale ? "Located \(locationAge) · may be out of date" : "Located \(locationAge)"
    }

    enum Charging: Equatable, Sendable { case charging, complete, pluggedIn, unplugged, unknown }

    var charging: Charging {
        switch snapshot.chargingState {
        case .charging?: .charging
        case .complete?: .complete
        case .stopped?: .pluggedIn
        case .disconnected?: .unplugged
        case nil: snapshot.state == .charging ? .charging : .unknown
        }
    }

    // MARK: Spoken answers

    var batteryDialog: String {
        var sentence = "\(name) is at \(batteryPercent)"
        if let range = spokenRange { sentence += " with about \(range) of \(rangeKind) range" }
        sentence += charging == .charging ? ", and charging." : "."
        if spokenRange == nil { sentence += " Range is unknown." }
        return "\(sentence) \(ageSentence)"
    }

    var rangeDialog: String {
        guard let range = spokenRange else {
            return "\(possessive) range is unknown. The battery is at \(batteryPercent). \(ageSentence)"
        }
        return "\(name) has about \(range) of \(rangeKind) range, with the battery at \(batteryPercent). \(ageSentence)"
    }

    var chargingDialog: String {
        let limit = snapshot.chargeLimit.map { "\($0)%" }
        let sentence: String
        switch charging {
        case .charging:
            var text = "\(name) is charging"
            if let kw = snapshot.chargerPowerKw, kw.isFinite, kw > 0 {
                text += " at \(kw.formatted(.number.precision(.fractionLength(kw >= 20 ? 0 : 1)))) kilowatts"
            }
            text += ", now at \(batteryPercent)."
            if let remaining = spokenTimeRemaining {
                text += limit.map { " About \(remaining) left to reach \($0)." } ?? " About \(remaining) left."
            } else {
                text += " Time remaining is unknown."
            }
            sentence = text
        case .complete:
            sentence = "\(name) has finished charging, at \(batteryPercent)."
        case .pluggedIn:
            sentence = "\(name) is plugged in but not charging, at \(batteryPercent)."
        case .unplugged:
            sentence = "\(name) isn’t plugged in. The battery is at \(batteryPercent)."
        case .unknown:
            sentence = "\(possessive) charging state is unknown. The battery is at \(batteryPercent)."
        }
        return "\(sentence) \(ageSentence)"
    }

    /// Uses only the saved place name and the position's own timestamp.
    var locationDialog: String {
        let driving = snapshot.state == .driving
        let sentence: String
        switch (place, hasLocation) {
        case (let place?, _): sentence = driving ? "\(name) is driving. It was last at \(place)." : "\(name) is at \(place)."
        case (nil, true): sentence = driving ? "\(name) is driving, away from your saved places." : "\(name) isn’t at a saved place."
        case (nil, false): sentence = driving ? "\(name) is driving. Its location is unknown." : "\(possessive) location is unknown."
        }
        return hasLocation ? "\(sentence) \(locationAgeSentence)" : sentence
    }

    var securityDialog: String {
        let doors: String = switch snapshot.locked {
        case true?: "\(name) is locked"
        case false?: "\(name) is unlocked"
        case nil: "\(possessive) lock state is unknown"
        }
        let sentry: String = switch snapshot.sentryMode {
        case true?: "Sentry Mode is on"
        case false?: "Sentry Mode is off"
        case nil: "Sentry Mode is unknown"
        }
        return "\(doors), and \(sentry). \(ageSentence)"
    }

    // MARK: Control and snippet labels

    var lockText: String {
        switch snapshot.locked {
        case true?: "Locked"
        case false?: "Unlocked"
        case nil: "Unknown"
        }
    }

    var sentryText: String {
        switch snapshot.sentryMode {
        case true?: "On"
        case false?: "Off"
        case nil: "Unknown"
        }
    }

    var climateText: String {
        switch snapshot.climateOn {
        case true?: "On"
        case false?: "Off"
        case nil: "Unknown"
        }
    }

    var chargingText: String {
        switch charging {
        // Controls pair this with a bolt icon, so the time alone fits the width.
        case .charging: shortTimeRemaining.map { "\($0) left" } ?? "Charging"
        case .complete: "Complete"
        case .pluggedIn: "Plugged in"
        case .unplugged: "Unplugged"
        case .unknown: "Unknown"
        }
    }

    /// "72% · 204 mi", or "72%" when range is unknown.
    var batteryText: String {
        shortRange.map { "\(batteryPercent) · \($0)" } ?? batteryPercent
    }

    /// Appends the age to a control value when the reading is stale: "Locked · 3h".
    func controlValue(_ text: String) -> String {
        isStale ? "\(text) · \(shortAge)" : text
    }

    /// SF Symbol for the battery level, with a bolt while charging.
    var batterySymbol: String {
        let level = snapshot.batteryLevel
        if charging == .charging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Text for controls and answers when there is no snapshot at all.
enum VehicleReadoutUnknown {
    static let value = "Unknown"
    static let noReadingDialog = "Volta doesn’t have a reading for your car yet. Open Volta to refresh it."
}

/// Labels for the lock and climate toggles. `isOn` is what the system shows:
/// the observed value, or the requested one while an action runs. A request
/// in flight says so ("Locking…"); a settled unknown value says "Unknown".
enum VehicleToggleLabel {
    struct Content: Equatable, Sendable {
        var text: String
        var symbol: String
    }

    static func lock(observed: Bool?, isOn: Bool, readout: VehicleReadout?) -> Content {
        if isOn != (observed == true) {
            return Content(text: isOn ? "Locking…" : "Unlocking…", symbol: isOn ? "lock.fill" : "lock.open.fill")
        }
        switch observed {
        case true?: return Content(text: settled("Locked", readout), symbol: "lock.fill")
        case false?: return Content(text: settled("Unlocked", readout), symbol: "lock.open.fill")
        case nil: return Content(text: VehicleReadoutUnknown.value, symbol: "lock")
        }
    }

    static func climate(observed: Bool?, isOn: Bool, readout: VehicleReadout?) -> Content {
        if isOn != (observed == true) {
            return Content(text: isOn ? "Turning On…" : "Turning Off…", symbol: isOn ? "fan.fill" : "fan")
        }
        switch observed {
        case true?: return Content(text: settled("On", readout), symbol: "fan.fill")
        case false?: return Content(text: settled("Off", readout), symbol: "fan")
        case nil: return Content(text: VehicleReadoutUnknown.value, symbol: "fan")
        }
    }

    private static func settled(_ text: String, _ readout: VehicleReadout?) -> String {
        readout?.controlValue(text) ?? text
    }
}
