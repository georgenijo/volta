import SwiftUI

/// What kind of charger a place is, from what the app already records:
/// `fastCharger` and the Tesla brand (`ChargePlace.network`) for DC, the
/// "home" place-name rule (`ChargeSummary.kind`) for home. Nothing new is inferred.
enum ChargerKind: Hashable, Sendable {
    case home
    case publicAC
    case supercharger
    case dcFast
    /// A place whose sessions don't agree on a kind, or have none.
    case unknown

    init(_ charge: ChargeSummary) {
        if charge.fastCharger {
            self = ChargePlace.network(charge) != nil ? .supercharger : .dcFast
        } else {
            self = charge.kind == .home ? .home : .publicAC
        }
    }

    /// A place's kind from its recorded sessions: their kind when every one
    /// agrees, otherwise (conflicting, or no sessions) unknown. A DC session
    /// whose network wasn't recorded is missing evidence, not a conflict: it
    /// agrees with any DC kind, and alone makes the place generic DC. Every
    /// map shows a place the same way.
    init<S: Sequence>(agreeing sessions: S) where S.Element == ChargeSummary {
        var kinds = Set<ChargerKind>()
        var unbrandedDC = false
        for session in sessions {
            if session.fastCharger, (session.fastChargerBrand ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                unbrandedDC = true
            } else {
                kinds.insert(ChargerKind(session))
            }
        }
        guard kinds.count <= 1 else { self = .unknown; return }
        switch kinds.first {
        case nil: self = unbrandedDC ? .dcFast : .unknown
        case .supercharger?, .dcFast?: self = kinds.first!
        case let kind?: self = unbrandedDC ? .unknown : kind
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .publicAC: "powerplug.fill"
        case .supercharger: "bolt.fill"
        case .dcFast: "bolt.fill"
        case .unknown: "ev.charger.fill"
        }
    }

    /// Badge fills: the same in both appearances by design, like a charger
    /// network's sign. Each sits on a white ring, so it reads on light and dark
    /// maps alike.
    var fill: Color {
        switch self {
        case .home: Color(hex: 0x3B82F6)  // appearance: fixed (badge)
        case .publicAC: Color(hex: 0x5ECB93)  // appearance: fixed (badge)
        case .supercharger: HistoryTheme.teslaRed
        case .dcFast: Color(hex: 0xF59E0B)  // appearance: fixed (badge)
        case .unknown: Color(hex: 0x6B7078)  // appearance: fixed (badge)
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .publicAC: "AC charger"
        case .supercharger: "Tesla Supercharger"
        case .dcFast: "DC fast charger"
        case .unknown: "Charging place"
        }
    }
}

/// A charging place on a map or in a row: a filled disc with a white ring and
/// the kind's glyph (the Tesla network keeps its red "T" badge). 28 pt on maps.
struct ChargerBadge: View {
    var kind: ChargerKind
    var size: CGFloat = 28

    var body: some View {
        let ring = max(1, size / 14)
        ZStack {
            Circle().fill(kind.fill)
            if kind == .supercharger {
                Text("T").font(.system(size: size * 0.5, weight: .heavy)).foregroundStyle(.voltaOnAccent)
            } else {
                Image(systemName: kind.systemImage)
                    .font(.system(size: size * 13 / 28, weight: .semibold))
                    .foregroundStyle(.voltaOnAccent)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.voltaOnAccent, lineWidth: ring))
        .shadow(color: Color.voltaShadow.opacity(size >= 24 ? 0.35 : 0), radius: 3, y: 1)
        .accessibilityHidden(true)
    }
}
