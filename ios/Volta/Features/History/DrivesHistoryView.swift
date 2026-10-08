import SwiftUI

enum DriveFilter: String, CaseIterable, Identifiable {
    case all, short, medium, long
    var id: String { rawValue }

    /// Bucket edges in km (≈10 mi and ≈50 mi).
    static let shortKm = 16.0934
    static let longKm = 80.4672

    func title(_ units: UnitPreferences) -> String {
        let s = VoltaFormat.number(units.distanceValue(km: Self.shortKm), digits: 0)
        let l = VoltaFormat.number(units.distanceValue(km: Self.longKm), digits: 0)
        let u = units.distanceUnit
        return switch self {
        case .all: "Any distance"
        case .short: "Under \(s) \(u)"
        case .medium: "\(s)–\(l) \(u)"
        case .long: "Over \(l) \(u)"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .short: "building.2"
        case .medium: "road.lanes"
        case .long: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    func matches(_ drive: DriveSummary) -> Bool {
        switch self {
        case .all: true
        case .short: drive.distanceKm < Self.shortKm
        case .medium: drive.distanceKm >= Self.shortKm && drive.distanceKm <= Self.longKm
        case .long: drive.distanceKm > Self.longKm
        }
    }
}

enum DriveSort: String, CaseIterable, Identifiable {
    case newest, longest, mostEfficient
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: "Newest first"
        case .longest: "Longest first"
        case .mostEfficient: "Most efficient first"
        }
    }
}

extension DriveSummary {
    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [startAddress, endAddress].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    var batteryUsed: Int? {
        guard let s = startBatteryLevel, let e = endBatteryLevel else { return nil }
        return s - e
    }

    /// Efficiency tint relative to a typical Model Y (~165 Wh/km is average).
    var efficiencyTint: Color {
        guard let e = efficiencyWhPerKm else { return HistoryTheme.secondary }
        return e < 140 ? HistoryTheme.green : e < 190 ? HistoryTheme.blue : HistoryTheme.amber
    }
}

/// Drives tab: range pill + filter, search, day-grouped drive cards.
struct DrivesHistoryView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units

    @State private var feed = HistoryFeed<DriveSummary>()
    @State private var range: HistoryRange
    @State private var filter: DriveFilter = .all
    @State private var sort: DriveSort = .newest
    @State private var searching = false
    @State private var query = ""

    init(range: HistoryRange = .all) {
        _range = State(initialValue: range)
    }

    private var visible: [DriveSummary] {
        let items = feed.items.filter { filter.matches($0) && $0.matches(query: query) }
        switch sort {
        case .newest: return items
        case .longest: return items.sorted { $0.distanceKm > $1.distanceKm }
        case .mostEfficient: return items.sorted { ($0.efficiencyWhPerKm ?? .infinity) < ($1.efficiencyWhPerKm ?? .infinity) }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HistoryHeader(title: "Drives", range: $range, filterActive: filter != .all || sort != .newest) {
                    Picker("Distance", selection: $filter) {
                        ForEach(DriveFilter.allCases) { f in
                            Label(f.title(units), systemImage: f.systemImage).tag(f)
                        }
                    }
                    Picker("Sort", selection: $sort) {
                        ForEach(DriveSort.allCases) { Text($0.title).tag($0) }
                    }
                } trailing: {
                    HistoryHeaderButton(systemImage: "magnifyingglass", label: "Search", isOn: searching) {
                        withAnimation(.snappy) { searching.toggle(); if !searching { query = "" } }
                    }
                }
                if searching {
                    HistorySearchField(text: $query, prompt: "Search addresses") {
                        withAnimation(.snappy) { searching = false }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .historyScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: DriveSummary.self) { DriveDetailView(drive: $0) }
        }
        .task(id: range) { await reload(skeleton: true) }
    }

    private func reload(skeleton: Bool = false) async {
        let ds = dataSource, vid = vehicleID
        await feed.reload(range: range.dateRange(), fetch: { r, c in
            try await ds.drives(vehicleID: vid, range: r, cursor: c)
        }, showSkeleton: skeleton)
    }

    @ViewBuilder private var content: some View {
        switch feed.phase {
        case .loading:
            HistorySkeletonList()
        case .failed(let message):
            HistoryErrorState(title: "Couldn't load drives", message: message) {
                Task { await reload(skeleton: true) }
            }
        case .loaded:
            if feed.items.isEmpty {
                if let phrase = range.emptyPhrase {
                    HistoryEmptyState(systemImage: "road.lanes", title: "No drives \(phrase)",
                                      message: "Try a different range or wait for your next drive.")
                } else {
                    HistoryEmptyState(systemImage: "road.lanes", title: "No drives yet",
                                      message: "Your driving history will appear here once you start using your vehicle.")
                }
            } else if visible.isEmpty && !feed.hasMore {
                HistoryEmptyState(systemImage: "line.3.horizontal.decrease", title: "No matching drives",
                                  message: "Try a different search or distance filter.")
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                totals.padding(.bottom, 20)
                if sort == .newest {
                    ForEach(DayGroup.group(visible, by: \.start)) { group in
                        SectionLabel(group.title, trailing: units.formatDistance(group.items.reduce(0) { $0 + $1.distanceKm }))
                            .padding(.top, 14)
                            .padding(.bottom, 12)
                        rows(group.items)
                    }
                } else {
                    SectionLabel(sort.title, trailing: "\(visible.count) drives")
                        .padding(.top, 14).padding(.bottom, 12)
                    rows(visible)
                }
                HistoryPageFooter(feed: feed) { await reload() }
            }
            .padding(.horizontal, HistoryTheme.gutter)
        }
        .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .refreshable { await reload() }
    }

    private func rows(_ items: [DriveSummary]) -> some View {
        VStack(spacing: 10) {
            ForEach(items) { drive in
                NavigationLink(value: drive) { DriveRow(drive: drive, showsDate: sort != .newest) }
                    .buttonStyle(VoltaPressStyle())
                    .accessibilityIdentifier("row.drive.\(drive.id)")
            }
        }
    }

    private var totals: some View {
        let totals = DriveTotals(visible)
        return HistoryTotalsBlock(
            title: HistoryTotalsScope.title(period: range.periodLabel, hasMore: feed.hasMore, noun: "drives"),
            isPartial: feed.hasMore,
            items: [
                .init(label: units.distanceUnit, value: VoltaFormat.number(units.distanceValue(km: totals.distanceKm), digits: 0), unit: nil),
                .init(label: visible.count == 1 ? "Drive" : "Drives", value: "\(visible.count)\(feed.hasMore ? "+" : "")", unit: nil),
                .init(label: units.efficiencyUnit, value: totals.efficiencyWhPerKm.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) } ?? "—", unit: nil),
            ],
            notes: totals.notes)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("screen.drives")
    }
}

// MARK: - Row

struct DriveRow: View {
    var drive: DriveSummary
    var showsDate = false
    @Environment(\.units) private var units

    var body: some View {
        HistoryCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    RouteGlyph()
                        .frame(width: 14, height: 46)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 0) {
                        endpoint(drive.startAddress, time: drive.start)
                        Spacer(minLength: 8)
                        endpoint(drive.endAddress, time: drive.end)
                    }
                    .frame(height: 54)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        HistoryValue(value: VoltaFormat.number(units.distanceValue(km: drive.distanceKm)), unit: units.distanceUnit, size: 22)
                        Text(VoltaFormat.duration(drive.durationMin))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(HistoryTheme.secondary)
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 16) {
                    HistoryInlineMetric(systemImage: "leaf.fill", text: units.formatEfficiency(drive.efficiencyWhPerKm), tint: drive.efficiencyTint)
                    HistoryInlineMetric(systemImage: "battery.50percent", text: drive.batteryUsed.map { "−\($0)%" } ?? "—")
                    if let kwh = drive.energyUsedKwh {
                        HistoryInlineMetric(systemImage: "bolt.fill", text: VoltaFormat.energy(kwh))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HistoryTheme.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func endpoint(_ address: String?, time: Date?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(address ?? "Unknown")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let time {
                Text(showsDate ? time.formatted(.dateTime.month(.abbreviated).day().hour().minute()) : time.historyTime)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HistoryTheme.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// Start dot, dashed connector, end pin — a cheap stand-in for a route
/// thumbnail (summaries carry no path).
struct RouteGlyph: View {
    var body: some View {
        VStack(spacing: 3) {
            Circle()
                .strokeBorder(HistoryTheme.secondary, lineWidth: 2)
                .frame(width: 10, height: 10)
            Line()
                .stroke(HistoryTheme.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                .frame(width: 1.5)
            Circle()
                .fill(HistoryTheme.blue)
                .frame(width: 10, height: 10)
                .shadow(color: HistoryTheme.blue.opacity(0.6), radius: 4)
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in p.move(to: CGPoint(x: rect.midX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)) }
        }
    }
}

#Preview("Drives") {
    DrivesHistoryView()
        .environment(\.dataSource, MockDataSource())
        .preferredColorScheme(.dark)
}

#Preview("Drives · empty") {
    DrivesHistoryView()
        .environment(\.dataSource, MockDataSource(empty: true))
        .preferredColorScheme(.dark)
}

#Preview("Drives · error") {
    DrivesHistoryView()
        .environment(\.dataSource, HistoryPreviewFailingSource())
        .preferredColorScheme(.dark)
}
