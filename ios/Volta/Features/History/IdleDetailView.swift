import SwiftUI

/// One stop. There is no detail endpoint; everything comes from the summary.
/// Range lost in the user's unit is the main figure, with the battery
/// percentage and the estimated energy beside it.
struct IdleDetailView: View {
    var idle: IdleSummary

    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @Environment(\.barsOnSide) private var barsOnSide
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 52
    @State private var places = HistoryPlaces()
    @State private var page = HistoryWindow()

    /// Wide enough for two columns (the inner display with the list hidden).
    private var usesPanes: Bool { page.isWide && page.size.width >= HistoryLayout.panesMinWidth }

    var body: some View {
        Group {
            if usesPanes {
                VoltaPanes {
                    column { hero.voltaFocusIn(0); location.voltaFocusIn(1) }
                } secondary: {
                    column(titled: false) { stats.voltaFocusIn(1); breakdownCard.voltaFocusIn(2); timesCard.voltaFocusIn(3) }
                }
            } else {
                column {
                    hero.voltaFocusIn(0); location.voltaFocusIn(1); stats.voltaFocusIn(2)
                    breakdownCard.voltaFocusIn(3); timesCard.voltaFocusIn(4)
                }
            }
        }
        .readsHistoryWindow($page)
        .historyPage("Stop")
        .task { if idle.needsPlaces { await places.load(dataSource: dataSource, vehicleID: vehicleID) } }
    }

    private func column<Content: View>(titled: Bool = true, @ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if barsOnSide && titled { HistoryInlineTitle(title: "Stop") }
                content()
            }
            .padding(.horizontal, VoltaSpacing.screen)
            .padding(.top, 8)
            .voltaReadableWidth()
        }
        .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.idle-detail")
    }

    private var location: some View {
        HistoryLocationCard(location: idle.location(places.state), address: idle.address,
                            systemImage: "parkingsign", tint: HistoryTheme.blue) {
            Task { await places.retry(dataSource: dataSource, vehicleID: vehicleID) }
        }
    }

    private var text: ParkedText { ParkedText(units: units) }
    private var loss: ParkedLoss { ParkedLoss(idle) }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                HistoryIconTile(systemImage: "parkingsign", tint: HistoryTheme.blue)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(idle.placeLabel)
                        .font(.system(.title3, weight: .bold))
                        .foregroundStyle(Color.voltaTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("screen.idle-detail")
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(HistoryTheme.secondary)
                }
            }
            figure
            BatteryRangeView(from: idle.batteryEndpoints.from, to: idle.batteryEndpoints.to, tint: HistoryTheme.blue)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(batterySpoken)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var figure: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .lastTextBaseline, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 4) {
                Text("Range lost").voltaLabelStyle()
                switch loss {
                case .lost(let km, _):
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        RollingNumber(value: text.rowValue(km)) { "−" + VoltaFormat.number($0, digits: 1) }
                            .font(.system(size: numberSize, weight: .heavy))
                            .tracking(-1)
                            .lineLimit(1).minimumScaleFactor(0.5)
                        Text(units.distanceUnit).font(.body).foregroundStyle(HistoryTheme.secondary)
                    }
                    .foregroundStyle(Color.voltaTextPrimary)
                default:
                    Text(text.lossLine(loss))
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(Color.voltaTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Range lost: \(text.spokenLoss(loss))")
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                Text("Parked").voltaLabelStyle()
                Text(ParkedText.span(idle.durationMin))
                    .font(.system(.title2, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.voltaTextPrimary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Parked \(ParkedText.spokenSpan(idle.durationMin))")
        }
    }

    private var batterySpoken: String {
        switch (idle.startBatteryLevel, idle.endBatteryLevel) {
        case let (s?, e?): "Battery \(s) percent when parked, \(e) percent when it left"
        case let (s?, nil): "Battery \(s) percent when parked"
        default: "Battery level not recorded"
        }
    }

    private var subtitle: String {
        let day = idle.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let place = idle.address.flatMap { $0 == idle.placeLabel ? nil : " · " + $0 } ?? ""
        return day + place
    }

    private var stats: some View {
        let rate: String
        switch loss {
        case .lost(_, let perDay?): rate = VoltaFormat.number(units.distanceValue(km: perDay))
        case .noLoss where idle.durationMin >= ParkedRules.rateMinMinutes: rate = "0"
        default: rate = "—"
        }
        return HistoryStatGrid(items: [
            .init(label: "Lost per day", value: rate, unit: units.distanceUnit, systemImage: "calendar"),
            .init(label: "Battery used", value: idle.drain.map { $0 > 0 ? "−\($0)" : "\($0)" } ?? "—", unit: "%", systemImage: "battery.50percent"),
            .init(label: "Energy lost", value: idle.isLive ? "—" : idle.energyLostKwh.map { "≈" + VoltaFormat.number($0, digits: 2) } ?? "—",
                  unit: "kWh", systemImage: "bolt"),
        ])
    }

    private var breakdownCard: some View {
        let slices = idle.breakdown
        let total = max(1, slices.reduce(0) { $0 + $1.minutes })
        return HistoryCard {
            VStack(alignment: .leading, spacing: 16) {
                HistorySectionLabel(title: "Where the time went", systemImage: "chart.bar.xaxis")
                if slices.isEmpty {
                    Text("The car's state wasn't recorded for this stop.")
                        .font(.subheadline)
                        .foregroundStyle(HistoryTheme.secondary)
                } else {
                    IdleBreakdownBar(slices: slices, height: 12)
                    VStack(spacing: 0) {
                        ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                            if index > 0 { HairlineDivider(leadingInset: 46) }
                            HStack(spacing: 12) {
                                HistoryIconTile(systemImage: slice.systemImage, tint: slice.color)
                                    .scaleEffect(0.85)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(slice.kind.rawValue)
                                        .font(.system(.subheadline, weight: .semibold))
                                        .foregroundStyle(Color.voltaTextPrimary)
                                    Text(slice.detail)
                                        .font(.caption)
                                        .foregroundStyle(HistoryTheme.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(VoltaFormat.duration(slice.minutes))
                                        .font(.system(.subheadline, weight: .semibold))
                                        .foregroundStyle(Color.voltaTextPrimary)
                                        .monospacedDigit()
                                    Text("\(Int((slice.minutes / total * 100).rounded()))%")
                                        .font(.system(.caption, weight: .medium))
                                        .foregroundStyle(HistoryTheme.secondary)
                                        .monospacedDigit()
                                }
                            }
                            .padding(.vertical, 10)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(slice.kind.rawValue): \(ParkedText.spokenSpan(slice.minutes)), \(Int((slice.minutes / total * 100).rounded())) percent")
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
                .font(.subheadline)
                .foregroundStyle(HistoryTheme.secondary)
            Spacer()
            Text(date.map { VoltaFormat.dayTime($0) } ?? "Still parked")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Color.voltaTextPrimary)
            Text(battery.map { "\($0)%" } ?? "—")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(HistoryTheme.secondary)
                .monospacedDigit()
                .frame(minWidth: 48, alignment: .trailing)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Stop") {
    NavigationStack {
        IdleDetailView(idle: IdleSummary(id: 1, start: .now.addingTimeInterval(-9 * 3600), end: .now.addingTimeInterval(-3600),
                                         address: "Palo Alto, CA", placeName: "Home", durationMin: 480,
                                         startBatteryLevel: 74, endBatteryLevel: 72, rangeLostKm: 7.1, energyLostKwh: 1.4,
                                         sentryMinutes: nil, climateMinutes: 15, asleepMinutes: 340))
    }
    .environment(\.dataSource, MockDataSource())
}

#Preview("Stop · unrecorded") {
    NavigationStack {
        IdleDetailView(idle: IdleSummary(id: 2, start: .now.addingTimeInterval(-3600), end: nil,
                                         address: "Union City, CA", placeName: nil, durationMin: 45,
                                         startBatteryLevel: nil, endBatteryLevel: nil, rangeLostKm: nil, energyLostKwh: nil,
                                         sentryMinutes: nil, climateMinutes: nil, asleepMinutes: nil))
    }
    .environment(\.dataSource, MockDataSource())
}
