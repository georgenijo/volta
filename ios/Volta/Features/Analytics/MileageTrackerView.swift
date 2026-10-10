import Charts
import SwiftUI

/// Distance per day / week / month with totals.
struct MileageTrackerView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var bucket: MileageBucketSize = .week
    @State private var state: Loadable<[MileageBucket]> = .loading
    @State private var selected: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ScreenKit.Segmented(options: MileageBucketSize.allCases.map { ($0, $0.rawValue.capitalized) }, selection: $bucket)
                LoadableContent(state: state, retry: load) { buckets in
                    if buckets.isEmpty {
                        EmptyState(systemImage: "gauge.with.needle", title: "No mileage yet",
                                   message: "Your distance per \(bucket.rawValue) appears after your first drive.")
                            .padding(.top, 40)
                    } else {
                        content(buckets.sorted { $0.start < $1.start })
                    }
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.mileage")
        .screenKitPage("Mileage Tracker")
        .task(id: TaskKey(vehicleID: vehicleID, bucket: bucket)) { await load() }
    }

    private struct TaskKey: Hashable { var vehicleID: Int; var bucket: MileageBucketSize }

    /// Most recent N buckets to keep bars legible.
    private var visibleCount: Int { bucket == .day ? 30 : bucket == .week ? 16 : 12 }

    @ViewBuilder
    private func content(_ all: [MileageBucket]) -> some View {
        let visible = Array(all.suffix(visibleCount))
        let total = all.reduce(0) { $0 + $1.distanceKm }
        let drives = all.reduce(0) { $0 + $1.driveCount }
        let average = total / Double(max(all.count, 1))
        // Selection is whichever returned bucket's interval contains the tapped date.
        let focus = selected.flatMap { AnalyticsMath.bucket(containing: $0, in: visible, size: bucket) } ?? visible.last

        VStack(alignment: .leading, spacing: 0) {
            AnalyticsHero(eyebrow: (focus.map { title(for: $0.start) } ?? "") + (focus.map { " · \($0.driveCount) drives" } ?? ""),
                          value: VoltaFormat.number(units.distanceValue(km: focus?.distanceKm ?? 0), digits: 0),
                          unit: units.distanceUnit, identifier: "screen.mileage")
            AnalyticsStatStrip(items: [
                (VoltaFormat.number(units.distanceValue(km: total), digits: 0), "\(units.distanceUnit) total"),
                (VoltaFormat.number(units.distanceValue(km: average), digits: 0), "Avg / \(bucket.rawValue)"),
                ("\(drives)", drives == 1 ? "Drive" : "Drives"),
                ("\(all.count)", "\(bucket.rawValue)s"),
            ])
            .padding(.top, 22)
            chart(visible, focus: focus, average: average).padding(.top, 26)

            AnalyticsSectionHeader("History", trailing: "Latest \(min(visibleCount, all.count))").padding(.top, AnalyticsStyle.sectionGap)
            let rows = Array(all.reversed().prefix(visibleCount))
            let peak = max(rows.map(\.distanceKm).max() ?? 1, 0.1)
            AnalyticsGroup {
                ForEach(Array(rows.enumerated()), id: \.element.start) { index, b in
                    AnalyticsRow(title: title(for: b.start),
                                 subtitle: "\(b.driveCount) drive\(b.driveCount == 1 ? "" : "s")" + (b.energyUsedKwh.map { " · \(VoltaFormat.energy($0, fractionDigits: 0))" } ?? ""),
                                 value: units.formatDistance(b.distanceKm, fractionDigits: 0),
                                 showsDivider: index < rows.count - 1) {
                        AnalyticsBar(fraction: b.distanceKm / peak,
                                     colors: b.start == focus?.start ? [AnalyticsStyle.mint, AnalyticsStyle.blue] : [.white.opacity(0.18), .white.opacity(0.32)],
                                     height: 3)
                    }
                }
            }
        }
    }

    private func chart(_ visible: [MileageBucket], focus: MileageBucket?, average: Double) -> some View {
        let entries = AnalyticsMath.intervals(visible, size: bucket)
        // One shared scale so the glow layer matches the bars it lights.
        let top = max(units.distanceValue(km: max(visible.map(\.distanceKm).max() ?? 0, average)), 1)
        return VStack(alignment: .leading, spacing: 10) {
            AnalyticsGlowChart(height: 170) { ghost in
                // Bars sit mid-interval on the same explicit intervals selection uses.
                Chart(entries, id: \.bucket.start) { entry in
                    let b = entry.bucket
                    let lit = b.start == focus?.start
                    BarMark(x: .value("Date", entry.interval.start.addingTimeInterval(entry.interval.duration / 2)),
                            y: .value("Distance", ghost && !lit ? 0 : units.distanceValue(km: b.distanceKm)),
                            width: .fixed(bucket == .day ? 5 : 8))
                        .foregroundStyle(lit ? AnyShapeStyle(LinearGradient(colors: [AnalyticsStyle.mint, AnalyticsStyle.blue], startPoint: .top, endPoint: .bottom))
                                         : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom)))
                        .clipShape(Capsule())
                    if b.start == visible.first?.start, !ghost {
                        RuleMark(y: .value("Average", units.distanceValue(km: average)))
                            .foregroundStyle(.white.opacity(0.22))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    }
                }
                .chartXSelection(value: $selected.animation(.snappy))
                .chartYScale(domain: 0...top)
                .chartXScale(range: .plotDimension(startPadding: 10, endPadding: 16))
                .chartStyled(ghost: ghost)
                // Server buckets start at UTC boundaries; lay bars out on the same calendar.
                .environment(\.calendar, AnalyticsMath.utcCalendar)
                .environment(\.timeZone, AnalyticsMath.utcCalendar.timeZone)
            }
            HStack {
                Text("Tap a bar to inspect it")
                Spacer()
                HStack(spacing: 6) {
                    Rectangle().fill(.white.opacity(0.3)).frame(width: 12, height: 1)
                    Text("Average")
                }
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(AnalyticsStyle.tertiary)
        }
    }

    /// Labels use UTC, matching the server's bucket boundaries.
    private func title(for date: Date) -> String {
        var style = Date.FormatStyle.dateTime
        style.timeZone = AnalyticsMath.utcCalendar.timeZone
        return switch bucket {
        case .day: date.formatted(style.weekday(.abbreviated).month(.abbreviated).day())
        case .week: "Week of " + date.formatted(style.month(.abbreviated).day())
        case .month: date.formatted(style.month(.wide).year())
        }
    }

    private func load() async {
        selected = nil
        do {
            let result = try await dataSource.mileage(vehicleID: vehicleID, bucket: bucket)
            withAnimation(.smooth) { state = .loaded(result) }
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

#Preview("Populated") {
    NavigationStack { MileageTrackerView() }.preferredColorScheme(.dark)
}

#Preview("Empty") {
    NavigationStack { MileageTrackerView() }
        .environment(\.dataSource, MockDataSource(empty: true))
        .preferredColorScheme(.dark)
}
