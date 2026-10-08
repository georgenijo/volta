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
            VStack(alignment: .leading, spacing: 18) {
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

        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(focus.map { title(for: $0.start) } ?? "", trailing: focus.map { "\($0.driveCount) drives" })
                ScreenKit.Numeral(value: VoltaFormat.number(units.distanceValue(km: focus?.distanceKm ?? 0), digits: 0), unit: units.distanceUnit, size: 52)
                // Bars span each bucket's explicit interval, the same intervals selection uses.
                Chart(AnalyticsMath.intervals(visible, size: bucket), id: \.bucket.start) { entry in
                    let b = entry.bucket
                    BarMark(xStart: .value("Start", entry.interval.start), xEnd: .value("End", entry.interval.end),
                            y: .value("Distance", units.distanceValue(km: b.distanceKm)))
                        .foregroundStyle(b.start == focus?.start ? AnyShapeStyle(ScreenKit.blue.gradient) : AnyShapeStyle(ScreenKit.blue.opacity(0.35)))
                        .clipShape(.rect(cornerRadius: 3))
                    if b.start == visible.first?.start {
                        RuleMark(y: .value("Average", units.distanceValue(km: average)))
                            .foregroundStyle(ScreenKit.secondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .chartXSelection(value: $selected.animation(.snappy))
                .chartStyled()
                .frame(height: 190)
                // Server buckets start at UTC boundaries; lay bars out on the same calendar.
                .environment(\.calendar, AnalyticsMath.utcCalendar)
                .environment(\.timeZone, AnalyticsMath.utcCalendar.timeZone)
            }
        }

        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ScreenKit.Metric(label: "Total", value: VoltaFormat.number(units.distanceValue(km: total), digits: 0), unit: units.distanceUnit,
                             caption: "\(drives) drives", symbol: "road.lanes")
            ScreenKit.Metric(label: "Avg / \(bucket.rawValue)", value: VoltaFormat.number(units.distanceValue(km: average), digits: 0),
                             unit: units.distanceUnit, caption: "\(all.count) \(bucket.rawValue)s", symbol: "chart.bar")
        }

        ScreenKit.GroupCard(title: "History") {
            let rows = Array(all.reversed().prefix(visibleCount))
            ForEach(Array(rows.enumerated()), id: \.element.start) { index, b in
                ScreenKit.ValueRow(title: title(for: b.start),
                                   subtitle: "\(b.driveCount) drive\(b.driveCount == 1 ? "" : "s")" + (b.energyUsedKwh.map { " · \(VoltaFormat.energy($0, fractionDigits: 0))" } ?? ""),
                                   showsDivider: index < rows.count - 1) {
                    Text(units.formatDistance(b.distanceKm, fractionDigits: 0))
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).monospacedDigit()
                }
            }
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
