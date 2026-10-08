import SwiftUI

/// Image shared from the trip screen. Deliberately contains no map, coordinates,
/// addresses or clock times: only the date and trip totals.
struct TripShareCard: View {
    var summary: DriveSummary
    var units: UnitPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("VOLTA")
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(3)
                    .foregroundStyle(HistoryTheme.secondary)
                Spacer()
                Text(summary.start.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
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
                stat("DURATION", VoltaFormat.duration(summary.durationMin))
                stat("ENERGY", summary.energyUsedKwh.map { "\(VoltaFormat.number($0)) kWh" } ?? "—")
                stat("BATTERY", summary.batteryUsed.map { "−\($0)%" } ?? "—")
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(HistoryTheme.background)
        .environment(\.colorScheme, .dark)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(HistoryTheme.secondary)
            Text(value).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
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
