import SwiftUI

/// Image shared from the trip screen. Deliberately contains no map, coordinates,
/// addresses or clock times: only the date and trip totals.
struct TripShareCard: View {
    var summary: DriveSummary
    var units: UnitPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Volta")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(HistoryTheme.secondary)
                Spacer()
                Text(summary.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HistoryTheme.secondary)
            }
            HStack(alignment: .lastTextBaseline) {
                BigNumber(VoltaFormat.number(units.distanceValue(km: summary.distanceKm)), unit: units.distanceUnit, size: 54)
                Spacer()
                if let eff = summary.efficiencyWhPerKm {
                    BigNumber(VoltaFormat.number(units.efficiencyValue(whPerKm: eff), digits: 0), unit: units.efficiencyUnit, size: 30)
                }
            }
            HStack(spacing: 0) {
                stat("Duration", VoltaFormat.duration(summary.durationMin))
                stat("Energy used", summary.energyUsedKwh.map { "\(VoltaFormat.number($0)) kWh" } ?? "—")
                stat("Battery used", summary.batteryUsed.map { "\($0)%" } ?? "—")
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(HistoryTheme.background)
        // The shared image keeps Volta's dark card whatever the sender's
        // appearance, so every card a person receives looks the same.
        .environment(\.colorScheme, .dark)  // appearance: fixed (share card)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
            Text(value).font(.system(size: 18, weight: .bold)).foregroundStyle(.voltaTextPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    static func render(_ summary: DriveSummary, units: UnitPreferences) -> Image? {
        let renderer = ImageRenderer(content: TripShareCard(summary: summary, units: units))
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) }
    }
}
