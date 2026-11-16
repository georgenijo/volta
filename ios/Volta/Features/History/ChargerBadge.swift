import SwiftUI

/// What kind of charger a place is, from what the app already records:
/// `fastCharger` and the Tesla brand (`ChargePlace.network`) for DC, the
/// "home" place-name rule (`ChargeSummary.kind`) for home. Nothing new is inferred.
enum ChargerKind: Hashable, Sendable {
    case home
    case publicAC
    case supercharger
    case dcFast
    /// A place whose kind the record doesn't say (Charger Map summaries).
    case unknown

    init(_ charge: ChargeSummary) {
        if charge.fastCharger {
            self = ChargePlace.network(charge) != nil ? .supercharger : .dcFast
        } else {
            self = charge.kind == .home ? .home : .publicAC
        }
    }

    /// Charger Map places carry only a name: the same "home" rule as a
    /// session, otherwise unknown.
    init(placeName: String) {
        self = placeName.localizedCaseInsensitiveContains("home") ? .home : .unknown
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

    var fill: Color {
        switch self {
        case .home: Color(hex: 0x3B82F6)
        case .publicAC: Color(hex: 0x5ECB93)
        case .supercharger: HistoryTheme.teslaRed
        case .dcFast: Color(hex: 0xF59E0B)
        case .unknown: Color(hex: 0x6B7078)
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
                Text("T").font(.system(size: size * 0.5, weight: .heavy)).foregroundStyle(.white)
            } else {
                Image(systemName: kind.systemImage)
                    .font(.system(size: size * 13 / 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white, lineWidth: ring))
        .shadow(color: .black.opacity(size >= 24 ? 0.35 : 0), radius: 3, y: 1)
        .accessibilityHidden(true)
    }
}
