import Foundation
import Observation

/// Commands sent from this device since the app launched, with what is known
/// about each outcome. In memory only: nothing is written to disk, and the
/// durable record of an unresolved send stays with `VehicleCommandCoordinator`.
///
/// Wording follows the evidence:
/// - Simulated: demo mode, no vehicle contacted.
/// - Accepted: the server acknowledged the command; observed status may lag.
/// - Confirmed: a status recorded after the send shows the expected state.
///   Only commands with an observable state can reach it.
@MainActor @Observable
final class VehicleCommandLog {
    /// The app-wide log, shared by the Dashboard and every Controls screen.
    static let shared = VehicleCommandLog()

    enum Outcome: Equatable, Sendable {
        case sending, simulated, accepted, confirmed, failed, unknown

        var text: String {
            switch self {
            case .sending: "Sending"
            case .simulated: "Simulated"
            case .accepted: "Accepted"
            case .confirmed: "Confirmed"
            case .failed: "Failed"
            case .unknown: "Outcome unknown"
            }
        }
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let id: UUID
        /// Backend and vehicle the command went to (`"backend|vehicle"`).
        let key: String
        let command: VehicleCommand
        let label: String
        let sentAt: Date
        var outcome: Outcome
        var updatedAt: Date
    }

    /// Newest last.
    private(set) var entries: [Entry] = []
    /// Oldest entries drop beyond this.
    var capacity = 50

    init() {}

    static func key(backendID: String, vehicleID: Int) -> String { "\(backendID)|\(vehicleID)" }

    /// Newest first, for one backend and vehicle.
    func entries(for key: String) -> [Entry] {
        entries.filter { $0.key == key }.reversed()
    }

    @discardableResult
    func begin(_ command: VehicleCommand, label: String, key: String, at date: Date = .now) -> UUID {
        let entry = Entry(id: UUID(), key: key, command: command, label: label, sentAt: date,
                          outcome: .sending, updatedAt: date)
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        return entry.id
    }

    func finish(_ id: UUID, with outcome: VehicleCommandCoordinator.Outcome, at date: Date = .now) {
        let mapped: Outcome = switch outcome {
        case .succeeded(let simulated): simulated ? .simulated : .accepted
        case .failed: .failed
        case .unknown: .unknown
        }
        update(id) { $0.outcome = mapped; $0.updatedAt = date }
    }

    /// Upgrades accepted commands that `status` shows took effect. A status
    /// recorded before the send proves nothing and is ignored.
    func observe(_ status: VehicleStatus, key: String) {
        for index in entries.indices where entries[index].key == key && entries[index].outcome == .accepted {
            let entry = entries[index]
            guard status.updatedAt >= entry.sentAt,
                  entry.command.isObserved(in: status) == true else { continue }
            entries[index].outcome = .confirmed
            entries[index].updatedAt = status.updatedAt
        }
    }

    private func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }
}

extension VehicleCommand {
    /// Whether `status` shows this command's effect: true or false for
    /// commands whose result the car reports, nil for those it does not
    /// (trunks, windows, lights, horn, HomeLink, wake, seats, wheel, defrost,
    /// cabin temperature) or when the field was not recorded.
    func isObserved(in status: VehicleStatus) -> Bool? {
        switch self {
        case .lock: status.locked.map { $0 }
        case .unlock: status.locked.map { !$0 }
        case .climateOn: status.climateOn.map { $0 }
        case .climateOff: status.climateOn.map { !$0 }
        case .sentryOn: status.sentryMode.map { $0 }
        case .sentryOff: status.sentryMode.map { !$0 }
        case .chargeStart: status.chargingState.map { $0 == .charging }
        case .chargeStop: status.chargingState.map { $0 != .charging }
        case .setChargeLimit(let percent): status.chargeLimit.map { $0 == percent }
        case .openChargePort: status.chargePortDoorOpen.map { $0 }
        case .closeChargePort: status.chargePortDoorOpen.map { !$0 }
        default: nil
        }
    }
}
