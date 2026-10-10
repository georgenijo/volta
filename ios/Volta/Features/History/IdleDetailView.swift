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
                VStack(alignment: .leading, spacing: 12) {
                    hero.padding(.bottom, 16)
                    HistoryLocationCard(location: idle.location(places.state), address: idle.address,
                                        systemImage: "parkingsign", tint: HistoryTheme.blue) {
                        Task { await places.retry(dataSource: dataSource, vehicleID: vehicleID) }
                    }
                    breakdownCard
                    timesCard
                }
                .padding(.horizontal, HistoryTheme.gutter)
                .padding(.top, 8)
            }
            .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
        .historyGlow(HistoryTheme.blue, HistoryTheme.purple, strength: 0.15)
        .historyScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task { if idle.needsPlaces { await places.load(dataSource: dataSource, vehicleID: vehicleID) } }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(subtitle).voltaLabelStyle(color: HistoryTheme.tertiary).lineLimit(1).minimumScaleFactor(0.8)
                Text(idle.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("screen.idle-detail")
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    let hours = idle.durationMin / 60
                    HistoryHeroNumeral(value: hours >= 1 ? VoltaFormat.number(hours, digits: hours >= 10 ? 0 : 1) : VoltaFormat.number(idle.durationMin, digits: 0),
                                       unit: hours >= 1 ? "h parked" : "min parked")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(drainTint).frame(width: 5, height: 5).shadow(color: drainTint, radius: 3)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        Text(idle.drain.map { $0 > 0 ? "−\($0)%" : "\($0)%" } ?? "—")
                            .font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                        Text("· \(VoltaFormat.duration(idle.durationMin)) · \(timeRange)")
                            .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
                SocDial(from: idle.startBatteryLevel, to: idle.endBatteryLevel, size: 96,
                        caption: idle.startBatteryLevel.map { "from \($0)%" } ?? "Battery",
                        colors: (idle.drainPerDay ?? 0) > 3 ? [HistoryTheme.amber, HistoryTheme.red] : [HistoryTheme.blue, HistoryTheme.purple])
                    .padding(.trailing, 4)
            }
            stats
        }
        .padding(.top, 6)
    }

    private var drainTint: Color { (idle.drainPerDay ?? 0) > 3 ? HistoryTheme.amber : HistoryTheme.blue }

    private var subtitle: String {
        let day = idle.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let place = idle.address.flatMap { $0 == idle.title ? nil : " · " + $0 } ?? ""
        return day + place
    }

    private var timeRange: String { idle.start.historyTime + " – " + (idle.end?.historyTime ?? "now") }

    private var stats: some View {
        HistoryStatStrip(items: [
            .init(value: idle.rangeLostKm.map { VoltaFormat.number(units.distanceValue(km: $0)) } ?? "—", caption: "\(units.distanceUnit) lost"),
            .init(value: idle.energyLostKwh.map { VoltaFormat.number($0, digits: 2) } ?? "—", caption: "kWh"),
            .init(value: idle.drainPerDay.map { VoltaFormat.number($0, digits: 1) + "%" } ?? "—", caption: "Per day",
                  accent: (idle.drainPerDay ?? 0) > 3 ? HistoryTheme.amber : nil),
            .init(value: idle.breakdown.first(where: { $0.kind == .asleep }).map { VoltaFormat.duration($0.minutes) } ?? "—", caption: "Asleep"),
        ])
    }

    private var breakdownCard: some View {
        let slices = idle.breakdown
        let total = max(1, slices.reduce(0) { $0 + $1.minutes })
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Where the time went").voltaLabelStyle(color: HistoryTheme.tertiary)
                if slices.isEmpty {
                    Text("State breakdown wasn't recorded for this session.")
                        .font(.system(size: 14))
                        .foregroundStyle(HistoryTheme.secondary)
                } else {
                    IdleBreakdownBar(slices: slices, height: 6)
                    VStack(spacing: 0) {
                        ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                            if index > 0 { HairlineDivider(leadingInset: 30) }
                            HStack(spacing: 12) {
                                Image(systemName: slice.systemImage)
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(slice.color)
                                    .shadow(color: slice.color.opacity(0.6), radius: 4)
                                    .frame(width: 18)
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
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 8)
        .driveSurface()
    }

    private var timesCard: some View {
        VStack(spacing: 0) {
            timeRow("Parked", idle.start, battery: idle.startBatteryLevel)
            HairlineDivider()
            timeRow("Left", idle.end, battery: idle.endBatteryLevel)
        }
        .padding(.horizontal, 18).padding(.vertical, 4)
        .driveSurface()
    }

    private func timeRow(_ label: String, _ date: Date?, battery: Int?) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
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
