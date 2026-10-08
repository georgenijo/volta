import SwiftUI

/// Idle sessions have no detail endpoint; everything comes from the summary.
struct IdleDetailView: View {
    var idle: IdleSummary

    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var places = HistoryPlaces()

    var body: some View {
        VStack(spacing: 0) {
            HistoryDetailHeader(title: "Parked")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    HistoryLocationCard(location: idle.location(places.state), address: idle.address,
                                        systemImage: "parkingsign", tint: HistoryTheme.blue) {
                        Task { await places.retry(dataSource: dataSource, vehicleID: vehicleID) }
                    }
                    stats
                    breakdownCard
                    timesCard
                }
                .padding(.horizontal, HistoryTheme.gutter)
                .padding(.top, 8)
            }
            .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
        .historyScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task { if idle.needsPlaces { await places.load(dataSource: dataSource, vehicleID: vehicleID) } }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                HistoryIconTile(systemImage: "parkingsign", tint: HistoryTheme.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(idle.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("screen.idle-detail")
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(HistoryTheme.secondary)
                        .lineLimit(1)
                }
            }
            HStack(alignment: .lastTextBaseline) {
                BigNumber(idle.drain.map { $0 > 0 ? "−\($0)" : "\($0)" } ?? "—", unit: "%", size: 56)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Parked").voltaLabelStyle()
                    BigNumber(VoltaFormat.duration(idle.durationMin), size: 26)
                }
            }
            BatteryRangeView(from: idle.batteryEndpoints.from, to: idle.batteryEndpoints.to, tint: drainTint)
        }
        .padding(.vertical, 6)
    }

    private var drainTint: Color { (idle.drainPerDay ?? 0) > 3 ? HistoryTheme.amber : HistoryTheme.blue }

    private var subtitle: String {
        let day = idle.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let place = idle.address.flatMap { $0 == idle.title ? nil : " · " + $0 } ?? ""
        return day + place
    }

    private var stats: some View {
        HistoryStatGrid(items: [
            .init(label: "Range lost", value: idle.rangeLostKm.map { VoltaFormat.number(units.distanceValue(km: $0)) } ?? "—", unit: units.distanceUnit, systemImage: "road.lanes"),
            .init(label: "Energy", value: idle.energyLostKwh.map { VoltaFormat.number($0, digits: 2) } ?? "—", unit: "kWh", systemImage: "bolt"),
            .init(label: "Per day", value: idle.drainPerDay.map { VoltaFormat.number($0, digits: 1) } ?? "—", unit: "%", systemImage: "calendar"),
        ])
    }

    private var breakdownCard: some View {
        let slices = idle.breakdown
        let total = max(1, slices.reduce(0) { $0 + $1.minutes })
        return HistoryCard {
            VStack(alignment: .leading, spacing: 16) {
                HistorySectionLabel(title: "Where the time went", systemImage: "chart.bar.xaxis")
                if slices.isEmpty {
                    Text("State breakdown wasn't recorded for this session.")
                        .font(.system(size: 14))
                        .foregroundStyle(HistoryTheme.secondary)
                } else {
                    IdleBreakdownBar(slices: slices, height: 12)
                    VStack(spacing: 0) {
                        ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                            if index > 0 { HairlineDivider(leadingInset: 46) }
                            HStack(spacing: 12) {
                                HistoryIconTile(systemImage: slice.systemImage, tint: slice.color)
                                    .scaleEffect(0.85)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(slice.kind.rawValue)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text(slice.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(HistoryTheme.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(VoltaFormat.duration(slice.minutes))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .monospacedDigit()
                                    Text("\(Int((slice.minutes / total * 100).rounded()))%")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(HistoryTheme.secondary)
                                        .monospacedDigit()
                                }
                            }
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
    }

    private var timesCard: some View {
        HistoryCard {
            VStack(spacing: 0) {
                timeRow("Parked", idle.start, battery: idle.startBatteryLevel)
                HairlineDivider()
                timeRow("Left", idle.end, battery: idle.endBatteryLevel)
            }
        }
    }

    private func timeRow(_ label: String, _ date: Date?, battery: Int?) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(HistoryTheme.secondary)
            Spacer()
            Text(date.map { $0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? "Still parked")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(battery.map { "\($0)%" } ?? "—")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(HistoryTheme.secondary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }
}

#Preview("Idle detail") {
    NavigationStack {
        IdleDetailView(idle: IdleSummary(id: 1, start: .now.addingTimeInterval(-9 * 3600), end: .now.addingTimeInterval(-3600),
                                         address: "Palo Alto, CA", placeName: "Home", durationMin: 480,
                                         startBatteryLevel: 74, endBatteryLevel: 72, rangeLostKm: 7.1, energyLostKwh: 1.4,
                                         sentryMinutes: 80, climateMinutes: 15, asleepMinutes: 340))
    }
    .environment(\.dataSource, MockDataSource())
    .preferredColorScheme(.dark)
}

#Preview("Idle detail · unrecorded") {
    NavigationStack {
        IdleDetailView(idle: IdleSummary(id: 2, start: .now.addingTimeInterval(-3600), end: nil,
                                         address: "Union City, CA", placeName: nil, durationMin: 45,
                                         startBatteryLevel: nil, endBatteryLevel: nil, rangeLostKm: nil, energyLostKwh: nil,
                                         sentryMinutes: nil, climateMinutes: nil, asleepMinutes: nil))
    }
    .environment(\.dataSource, MockDataSource())
    .preferredColorScheme(.dark)
}
