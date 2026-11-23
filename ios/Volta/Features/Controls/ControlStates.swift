import Foundation

/// How a possibly-unknown vehicle state is shown. Shared by the Dashboard quick
/// controls and the Controls sheet so both read the same for the same data.
/// `nil` from the server always renders as "Unknown" with a neutral symbol.
struct StateDisplay: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case active, inactive, unknown }

    var text: String
    var symbol: String
    var tone: Tone

    static func doors(_ locked: Bool?) -> StateDisplay {
        switch locked {
        case true?: .init(text: "Locked", symbol: "lock.fill", tone: .active)
        case false?: .init(text: "Unlocked", symbol: "lock.open.fill", tone: .inactive)
        case nil: .init(text: "Unknown", symbol: "lock", tone: .unknown)
        }
    }

    static func climate(_ on: Bool?) -> StateDisplay {
        switch on {
        case true?: .init(text: "On", symbol: "fan.fill", tone: .active)
        case false?: .init(text: "Off", symbol: "fan", tone: .inactive)
        case nil: .init(text: "Unknown", symbol: "fan", tone: .unknown)
        }
    }

    static func sentry(_ on: Bool?) -> StateDisplay {
        switch on {
        case true?: .init(text: "Armed", symbol: "shield.lefthalf.filled", tone: .active)
        case false?: .init(text: "Off", symbol: "shield", tone: .inactive)
        case nil: .init(text: "Unknown", symbol: "shield", tone: .unknown)
        }
    }

    static func charging(_ state: ChargingState?) -> StateDisplay {
        switch state {
        case .charging?: .init(text: "Charging", symbol: "bolt.fill", tone: .active)
        case .complete?: .init(text: "Complete", symbol: "bolt.badge.checkmark.fill", tone: .inactive)
        // Plugged in, not drawing power.
        case .stopped?: .init(text: "Stopped", symbol: "powerplug.fill", tone: .inactive)
        case .disconnected?: .init(text: "Unplugged", symbol: "powerplug", tone: .inactive)
        case nil: .init(text: "Unknown", symbol: "questionmark.circle", tone: .unknown)
        }
    }

    /// "80%" or "—" when the limit is unknown.
    static func chargeLimit(_ percent: Int?) -> String {
        percent.map { "\($0)%" } ?? "—"
    }
}
