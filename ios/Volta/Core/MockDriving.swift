import Foundation

/// A synthetic drive for demo mode, so the live driving card can be seen
/// without a car. DEBUG launch argument `-demoDriving <scenario>`; without it
/// demo mode stays parked. Bay Area coordinates only.
enum MockDriving: String, CaseIterable {
    /// A 60 s loop through town: pull away, cruise, brake with regen, wait at a light.
    case city
    /// Fixed moments for screenshots.
    case cruising, regen, stopped, parked
    /// The stream dropped a minute ago: readings kept, none live.
    case stale
    /// Driving per TeslaMate, with no gear, speed or power reported.
    case unknown

    static var current: MockDriving? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "demoDriving").flatMap(MockDriving.init(rawValue:))
        #else
        nil
        #endif
    }

    /// `parked` with this drive's readings, at `now`.
    func apply(to status: inout VehicleStatus, now: Date) {
        let moment = momentum(at: now)
        status.state = self == .parked ? .online : .driving
        status.updatedAt = now.addingTimeInterval(-2)
        status.locked = true
        status.sentryMode = false
        status.batteryLevel = 68
        status.usableBatteryLevel = 67
        status.estRangeKm = 309
        status.ratedRangeKm = 334
        // On the arterial between the demo towns, heading south-east.
        status.location = Location(latitude: 37.4290, longitude: -122.1170, heading: 128,
                                   address: "El Camino Real, Palo Alto, CA", placeName: nil)
        status.locationUpdatedAt = now
        let seen = now.addingTimeInterval(-1)
        func reading<T>(_ value: T, at: Date = seen, current: Bool = true) -> LiveDrive.Reading<T> {
            LiveDrive.Reading(value: value, observedAt: at, current: current, source: "fleet_telemetry")
        }
        switch self {
        case .city, .cruising, .regen, .stopped:
            status.telemetryFreshness = TelemetryFreshness(connected: true, lastSeenAt: seen, recordedAt: [:])
            if let speed = moment.speedKph {
                status.liveDrive = LiveDrive(gear: reading(.d, at: now.addingTimeInterval(-420)),
                                             speedKph: reading(speed), powerKw: reading(moment.powerKw))
            } else {
                // Stopped: the stream went quiet with the last creeping speed held.
                let quiet = now.addingTimeInterval(-moment.stoppedFor)
                status.liveDrive = LiveDrive(gear: reading(.d, at: now.addingTimeInterval(-420)),
                                             speedKph: reading(4, at: quiet, current: false),
                                             powerKw: reading(-1.8, at: quiet, current: false), stoppedSince: quiet)
            }
        case .parked:
            status.telemetryFreshness = TelemetryFreshness(connected: true, lastSeenAt: seen, recordedAt: [:])
            status.liveDrive = LiveDrive(gear: reading(.p, at: now.addingTimeInterval(-30)),
                                         speedKph: reading(0, at: now.addingTimeInterval(-32), current: false))
        case .stale:
            let lost = now.addingTimeInterval(-75)
            status.telemetryFreshness = TelemetryFreshness(connected: false, lastSeenAt: lost, recordedAt: [:])
            status.liveDrive = LiveDrive(gear: reading(.d, at: now.addingTimeInterval(-600), current: false),
                                         speedKph: reading(87, at: lost, current: false),
                                         powerKw: reading(24, at: lost, current: false))
        case .unknown:
            status.telemetryFreshness = nil
            status.liveDrive = nil
        }
    }

    private struct Moment { var speedKph: Double?; var powerKw: Double; var stoppedFor: TimeInterval }

    private func momentum(at now: Date) -> Moment {
        switch self {
        case .cruising: return Moment(speedKph: 64, powerKw: 14.6, stoppedFor: 0)
        case .regen: return Moment(speedKph: 41, powerKw: -27.4, stoppedFor: 0)
        case .stopped: return Moment(speedKph: nil, powerKw: 0, stoppedFor: 38)
        case .parked, .stale, .unknown: return Moment(speedKph: nil, powerKw: 0, stoppedFor: 0)
        case .city:
            let t = now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
            switch t {
            case ..<12: // pull away
                let f = t / 12
                return Moment(speedKph: 4 + 52 * f, powerKw: 68 - 40 * f, stoppedFor: 0)
            case ..<32: // cruise, a little up and down
                let wobble = sin((t - 12) / 20 * .pi * 2)
                return Moment(speedKph: 56 + 4 * wobble, powerKw: 13 + 6 * wobble, stoppedFor: 0)
            case ..<44: // brake for the light
                let f = (t - 32) / 12
                return Moment(speedKph: 56 * (1 - f) + 3 * f, powerKw: -34 * sin(f * .pi) - 2, stoppedFor: 0)
            default: // wait at the light
                return Moment(speedKph: nil, powerKw: 0, stoppedFor: t - 44)
            }
        }
    }
}
