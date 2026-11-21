import SwiftUI

/// Volta's haptics, named by what happened rather than by how it feels, so
/// the same event feels the same on every screen. Use through
/// `.voltaFeedback(_:trigger:)`; never call UIKit feedback generators directly.
///
///     .voltaFeedback(.commandConfirmed, trigger: confirmedCount)
///     .voltaFeedback(trigger: phase) { old, new in new == .failed ? .commandFailed : nil }
enum VoltaFeedback: Equatable {
    /// A command left the phone (Lock, Climate on…).
    case commandSent
    /// The car reported the new state.
    case commandConfirmed
    /// The command failed or the car refused it.
    case commandFailed
    /// A stepper or slider moved one step up.
    case stepUp
    /// A stepper or slider moved one step down.
    case stepDown
    /// A stepper or slider hit the end of its range.
    case limitReached
    /// A selection changed: a tab, a segment, a range, a vehicle.
    case selection
    /// A pull to refresh finished with new data.
    case refreshed

    var sensory: SensoryFeedback {
        switch self {
        case .commandSent: .impact(weight: .light)
        case .commandConfirmed: .success
        case .commandFailed: .error
        case .stepUp: .increase
        case .stepDown: .decrease
        case .limitReached: .impact(weight: .heavy, intensity: 0.8)
        case .selection: .selection
        case .refreshed: .impact(flexibility: .soft, intensity: 0.6)
        }
    }
}

extension View {
    /// Plays `feedback` each time `trigger` changes.
    func voltaFeedback<T: Equatable>(_ feedback: VoltaFeedback, trigger: T) -> some View {
        sensoryFeedback(feedback.sensory, trigger: trigger)
    }

    /// Plays whatever `feedback` returns for a change of `trigger`; nil plays nothing.
    func voltaFeedback<T: Equatable>(trigger: T, _ feedback: @escaping (T, T) -> VoltaFeedback?) -> some View {
        sensoryFeedback(trigger: trigger) { old, new in feedback(old, new)?.sensory }
    }
}
