import ActivityKit
import Foundation

// Compiled into BOTH the Volta app target (which starts/updates/ends the
// activities) and the VoltaWidgets extension (which renders them). The type
// names and Codable shapes must match in both, so never fork this file.
//
// Optional means unknown and renders as "—"; the app never substitutes a
// made-up value. Attributes carry the vehicle and session identity so the app
// can tell when a running activity no longer matches the car it shows.

/// Live Activity for a charging session.
struct ChargingActivityAttributes: ActivityAttributes, Hashable, Sendable {
    enum Phase: String, Codable, Hashable, Sendable {
        /// Charging right now.
        case charging
        /// Ended at the charge limit (final content).
        case completed
        /// Ended before the limit: stopped or unplugged (final content).
        case stopped

        var isFinal: Bool { self != .charging }
    }

    struct ContentState: Codable, Hashable, Sendable {
        var batteryLevel: Int
        var chargeLimit: Int?
        var chargerPowerKw: Double?
        /// Absolute ETA so the countdown keeps ticking between pushes.
        var fullAt: Date?
        var energyAddedKwh: Double?
        /// The car's charge counter as last read for this charge; `energyAddedKwh` may instead be
        /// a recorded total.
        var counterKwh: Double? = nil
        /// Whether the charge drew DC (true) or AC (false) power, when telemetry showed it.
        var fastCharger: Bool? = nil
        var rangeKm: Double?
        var phase: Phase = .charging
        /// When the vehicle data was recorded.
        var updatedAt: Date
        /// When the session ended. Set only for final phases.
        var endedAt: Date?
        /// The ids the status named for this activity's charge, each with its start: the Fleet
        /// Telemetry session (negative) and TeslaMate's process (positive, its charge id).
        var statusSessionId: Int? = nil
        var sessionStartedAt: Date? = nil
        var teslaMateChargeId: Int? = nil
        var teslaMateStartedAt: Date? = nil
        /// False when the session's start was not seen: it began mid-charge.
        var sessionStartObserved: Bool? = nil
        /// True when the charge continued into this session after a gap.
        var sessionResumed: Bool? = nil
        /// The sessions this charge ran in before `statusSessionId`, resumed from after gaps.
        var earlierSessionIds: [Int]? = nil
        /// Ids of the charges this activity replaced; never this charge's.
        var otherChargeIds: [Int]? = nil

        /// Battery fraction toward the charge limit, or nil when the limit is unknown.
        var fractionOfLimit: Double? {
            guard let chargeLimit, chargeLimit > 0 else { return nil }
            return min(1, max(0, Double(batteryLevel) / Double(chargeLimit)))
        }
    }

    var vehicleId: Int
    /// TeslaMate charge id of the open session, when the app could fetch it.
    var chargeId: Int?
    var vehicleName: String
    var placeName: String?
    var startedAt: Date?
    var startBatteryLevel: Int?
    /// nil when the session type is unknown.
    var fastCharger: Bool?
    var usesMiles: Bool
}

/// Optional Live Activity while the car is being driven.
struct DrivingActivityAttributes: ActivityAttributes, Hashable, Sendable {
    enum Phase: String, Codable, Hashable, Sendable {
        case driving
        /// The drive is over (final content).
        case ended

        var isFinal: Bool { self == .ended }
    }

    struct ContentState: Codable, Hashable, Sendable {
        var batteryLevel: Int
        var rangeKm: Double?
        /// Distance so far this drive; nil when the open drive is unknown.
        var distanceKm: Double?
        var energyUsedKwh: Double?
        var phase: Phase = .driving
        var updatedAt: Date
        var endedAt: Date?
    }

    var vehicleId: Int
    /// TeslaMate drive id of the open drive, when the app could fetch it.
    var driveId: Int?
    var vehicleName: String
    var startedAt: Date?
    var startAddress: String?
    var startBatteryLevel: Int?
    var usesMiles: Bool
}

/// Timing shared by the app (stale dates, dismissal) and the extension.
enum VoltaLiveActivityTiming {
    /// Charging content is marked stale this long after the vehicle data time.
    static let chargingStaleAfter: TimeInterval = 20 * 60
    /// Driving content changes faster, so it goes stale sooner.
    static let drivingStaleAfter: TimeInterval = 10 * 60
    /// How long final (ended) content stays visible before the system removes it.
    static let finalLinger: TimeInterval = 5 * 60
}
