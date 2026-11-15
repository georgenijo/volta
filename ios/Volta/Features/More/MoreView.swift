import SwiftUI

/// The More tab: an index of areas plus Settings.
///
/// Compact width (an ordinary iPhone, iPhone Duo's outer display): a list that
/// pushes each page. Regular width (iPhone Duo's inner display): a sidebar of
/// areas beside the selected page, as Mail shows a list beside a message.
/// Navigation carries over when the window changes between the two.
struct MoreView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.barsOnSide) private var barsOnSide
    /// Compact: the pushed pages.
    @State private var path: [MoreRoute] = []
    /// Regular: the page beside the sidebar, and what it has pushed.
    @State private var selection: MoreRoute?
    @State private var detailPath: [MoreRoute] = []
    /// The split view picked `selection` itself, so closing to compact width
    /// returns to the index rather than to a page nobody opened.
    @State private var selectionIsDefault = false
    @State private var vehicleName: String?
    /// Leading edge of iPhone Duo's fold while the device is partly folded,
    /// so the sidebar can take one side and the page the other.
    @State private var foldX: CGFloat?

    private var isSplit: Bool { horizontalSizeClass == .regular }

    var body: some View {
        Group {
            if isSplit { split } else { stack }
        }
        .onAppear { if isSplit { carryNavigation(toSplit: true) } }
        .onChange(of: isSplit) { _, split in carryNavigation(toSplit: split) }
        .task(id: vehicleID) {
            let vehicles = (try? await dataSource.vehicles()) ?? []
            vehicleName = vehicles.first(where: { $0.id == vehicleID })?.name ?? vehicles.first?.name
        }
    }

    // MARK: Areas

    private struct Item: Identifiable {
        var symbol: String
        var tint: Color
        var title: String
        /// Suffix of the row's `row.more.<slug>` accessibility identifier.
        var slug: String
        var route: MoreRoute
        var id: String { slug }
    }

    private struct Section: Identifiable {
        var title: String
        var dot: Color
        /// Identifier on the section title; the first one marks the screen for UI tests.
        var identifier: String?
        var items: [Item]
        var id: String { title }
    }

    private let sections: [Section] = [
        Section(title: "Areas", dot: ScreenKit.blue, identifier: "screen.more", items: [
            Item(symbol: "chart.xyaxis.line", tint: ScreenKit.blue, title: "Stats", slug: "stats", route: .stats),
        ]),
        Section(title: "Vehicle", dot: ScreenKit.mint, items: [
            Item(symbol: "battery.100percent.bolt", tint: ScreenKit.mint, title: "Battery Health", slug: "battery-health", route: .batteryHealth),
            Item(symbol: "thermometer.medium", tint: ScreenKit.mint, title: "Battery Climate", slug: "battery-climate", route: .batteryClimate),
            Item(symbol: "circle.circle", tint: ScreenKit.mint, title: "Tires", slug: "tires", route: .tires),
            Item(symbol: "wrench.and.screwdriver", tint: ScreenKit.mint, title: "Maintenance", slug: "maintenance", route: .maintenance),
            Item(symbol: "cpu", tint: ScreenKit.mint, title: "Firmware Tracker", slug: "firmware", route: .firmware),
            Item(symbol: "gauge.with.needle", tint: ScreenKit.mint, title: "Mileage Tracker", slug: "mileage", route: .mileage),
            Item(symbol: "checkmark.shield", tint: ScreenKit.mint, title: "Specs & Warranty", slug: "specs", route: .specs),
        ]),
        Section(title: "Explore", dot: ScreenKit.blue, items: [
            Item(symbol: "mappin.and.ellipse", tint: ScreenKit.blue, title: "Charger Map", slug: "charger-map", route: .chargerMap),
        ]),
    ]

    // MARK: Compact: push navigation

    private var stack: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if barsOnSide { indexTitle.padding(.top, VoltaSpacing.sm) }
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            ScreenKit.SectionHeader(title: section.title, dot: section.dot, identifier: section.identifier)
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                NavigationLink(value: item.route) {
                                    ScreenKit.NavRow(symbol: item.symbol, tint: item.tint, title: item.title,
                                                     showsDivider: index < section.items.count - 1)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("row.more.\(item.slug)")
                            }
                        }
                    }

                    VStack(spacing: 0) {
                        Rectangle().fill(ScreenKit.hairline).frame(height: 1)
                        NavigationLink(value: MoreRoute.switchVehicle) {
                            ScreenKit.CapsRow(symbol: "car.2.fill", tint: ScreenKit.mint, title: "Switch Vehicle",
                                              subtitle: vehicleName ?? "—")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("row.more.switch-vehicle")
                    }
                    .padding(.top, 36)

                    footer.padding(.top, 40)
                }
                .padding(.top, barsOnSide ? 0 : 8)
                .padding(.bottom, ScreenKit.bottomBarClearance)
                .voltaReadableWidth()
            }
            .accessibilityIdentifier("scroll.more")
            .scrollContentBackground(.hidden)
            .voltaScreenBackground()
            .modifier(IndexChrome(barsOnSide: barsOnSide) { path.append(.settings) })
            .moreDestinations()
        }
    }

    // MARK: Regular: sidebar and detail

    private var split: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(sidebarWidth)
        } detail: {
            NavigationStack(path: $detailPath) {
                Group {
                    if let selection {
                        selection.destination.id(selection)
                    } else {
                        EmptyState(systemImage: "square.grid.2x2", title: "Choose an area",
                                   message: "Stats, battery, tires, maintenance and settings open here.")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .voltaScreenBackground()
                    }
                }
                .moreDestinations()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onGeometryChange(for: CGFloat?.self) { proxy in
            guard #available(iOS 27.1, *) else { return nil }
            return proxy.reservedRegions(kind: .division).first(where: \.isActive).map(\.frame.minX)
        } action: { foldX = $0 }
    }

    /// Partly folded: the sidebar ends at the fold, so the page sits wholly on
    /// the other side. Otherwise a fixed sidebar width.
    private var sidebarWidth: CGFloat {
        guard let foldX, foldX > 240 else { return 300 }
        return min(foldX, 440)
    }

    /// Picking a row starts that page afresh, the way tapping it pushes it on compact.
    private var sidebarSelection: Binding<MoreRoute?> {
        Binding(get: { selection }, set: { route in
            guard route != selection || !detailPath.isEmpty else { return }
            selection = route
            detailPath = []
            selectionIsDefault = false
        })
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            if barsOnSide {
                indexTitle
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
            ForEach(sections) { section in
                SwiftUI.Section {
                    ForEach(section.items) { item in
                        sidebarRow(symbol: item.symbol, tint: item.tint, title: item.title)
                            .tag(item.route)
                            .accessibilityIdentifier("row.more.\(item.slug)")
                    }
                } header: {
                    sidebarHeader(section.title, dot: section.dot, identifier: section.identifier)
                }
            }
            SwiftUI.Section {
                sidebarRow(symbol: "car.2.fill", tint: ScreenKit.mint, title: "Switch Vehicle", subtitle: vehicleName ?? "—")
                    .tag(MoreRoute.switchVehicle)
                    .accessibilityIdentifier("row.more.switch-vehicle")
                sidebarRow(symbol: "gearshape.fill", tint: ScreenKit.secondary, title: "Settings")
                    .tag(MoreRoute.settings)
                    .accessibilityIdentifier("row.more.settings")
            } header: {
                sidebarHeader("App", dot: ScreenKit.secondary)
            } footer: {
                footer.padding(.top, 28)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("scroll.more")
        .voltaScreenBackground()
        .modifier(IndexChrome(barsOnSide: barsOnSide) { sidebarSelection.wrappedValue = .settings })
    }

    /// The index title, drawn in the content when the bars are on the side.
    /// It scrolls with the rows, as a large title would.
    private var indexTitle: some View {
        Text("More")
            .font(.system(.title2, weight: .bold))
            .foregroundStyle(Color.voltaTextPrimary)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, isSplit ? 0 : ScreenKit.horizontalPadding)
    }

    private func sidebarRow(symbol: String, tint: Color, title: String, subtitle: String? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.voltaTextPrimary)
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(ScreenKit.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func sidebarHeader(_ title: String, dot: Color, identifier: String? = nil) -> some View {
        HStack(spacing: 10) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(2)
                .foregroundStyle(ScreenKit.secondary)
                .accessibilityIdentifier(identifier ?? "")
        }
        .accessibilityAddTraits(.isHeader)
    }

    private var footer: some View {
        Text("Volta · v\(AppInfo.version) · private")
            .font(.system(size: 12, weight: .medium)).tracking(1)
            .foregroundStyle(ScreenKit.secondary.opacity(0.5))
            .frame(maxWidth: .infinity)
    }

    // MARK: Carrying navigation between widths

    /// Opening iPhone Duo shows the page that was open on the outer display
    /// beside the index; closing it shows the page that was selected.
    private func carryNavigation(toSplit: Bool) {
        if toSplit {
            if let first = path.first {
                selection = first
                detailPath = Array(path.dropFirst())
                selectionIsDefault = false
            } else if selection == nil {
                selection = .stats
                selectionIsDefault = true
            }
            path = []
        } else {
            if let selection, !(selectionIsDefault && detailPath.isEmpty) {
                path = [selection] + detailPath
            } else {
                path = []
            }
            detailPath = []
        }
    }
}

/// The More index's title and its Settings toolbar item, which iPhone Duo
/// moves into the side bar with the tabs.
private struct IndexChrome: ViewModifier {
    var barsOnSide: Bool
    var openSettings: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationTitle(barsOnSide ? "" : "More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                if !barsOnSide {
                    ToolbarItem(placement: .principal) {
                        Text("More")
                            .font(.voltaScreenTitle)
                            .foregroundStyle(Color.voltaTextPrimary)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: openSettings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tint(Color.voltaTextPrimary)
                    .accessibilityIdentifier("button.settings")
                }
            }
    }
}

/// Bundle version strings.
enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
}

#Preview("Populated") {
    MoreView().voltaPreviewEnvironment()
}

#Preview("Empty") {
    MoreView().voltaPreviewEnvironment(empty: true)
}
