import SwiftUI

/// The "…" screen: feature index with a gear button into Settings.
/// Owns its own NavigationStack (embedded by MainShell as a full screen).
struct MoreView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @State private var path: [MoreRoute] = []
    @State private var vehicleName: String?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section("Areas", dot: ScreenKit.blue, identifier: "screen.more", rows: [
                        .init(symbol: "chart.xyaxis.line", tint: ScreenKit.blue, title: "Stats", route: .stats),
                    ])
                    section("Vehicle", dot: ScreenKit.mint, rows: [
                        .init(symbol: "battery.100percent.bolt", tint: ScreenKit.mint, title: "Battery Health", route: .batteryHealth),
                        .init(symbol: "thermometer.medium", tint: ScreenKit.mint, title: "Battery Climate", route: .batteryClimate),
                        .init(symbol: "circle.circle", tint: ScreenKit.mint, title: "Tires", route: .comingLater(.tires), soon: true),
                        .init(symbol: "wrench.and.screwdriver", tint: ScreenKit.mint, title: "Maintenance", route: .maintenance),
                        .init(symbol: "cpu", tint: ScreenKit.mint, title: "Firmware Tracker", route: .firmware),
                        .init(symbol: "gauge.with.needle", tint: ScreenKit.mint, title: "Mileage Tracker", route: .mileage),
                        .init(symbol: "checkmark.shield", tint: ScreenKit.mint, title: "Specs & Warranty", route: .specs),
                    ])
                    section("Explore", dot: ScreenKit.blue, rows: [
                        .init(symbol: "mappin.and.ellipse", tint: ScreenKit.blue, title: "Charger Map", route: .chargerMap),
                    ])

                    switchVehicle.padding(.top, 36)
                    footer
                }
                .padding(.top, 8)
                .padding(.bottom, ScreenKit.bottomBarClearance)
            }
            .accessibilityIdentifier("scroll.more")
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Spacer()
                    GlassCircleButton(systemImage: "gearshape", accessibilityLabel: "Settings") { path.append(.settings) }
                        .accessibilityIdentifier("button.settings")
                }
                .padding(.horizontal, VoltaSpacing.screen - 4)
                .frame(minHeight: 56)
                .padding(.bottom, VoltaSpacing.sm)
                .background {
                    LinearGradient(colors: [Color.voltaBackground, Color.voltaBackground.opacity(0.85), Color.voltaBackground.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .top)
                }
            }
            .voltaScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .moreDestinations()
            .task(id: vehicleID) {
                let vehicles = (try? await dataSource.vehicles()) ?? []
                vehicleName = vehicles.first(where: { $0.id == vehicleID })?.name ?? vehicles.first?.name
            }
        }
    }

    private struct Item {
        var symbol: String
        var tint: Color
        var title: String
        var route: MoreRoute
        var soon = false
    }

    private func section(_ title: String, dot: Color, identifier: String? = nil, rows: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenKit.SectionHeader(title: title, dot: dot, identifier: identifier)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, item in
                NavigationLink(value: item.route) {
                    ScreenKit.NavRow(symbol: item.symbol, tint: item.tint, title: item.title,
                                     trailing: item.soon ? "Soon" : nil,
                                     showsDivider: index < rows.count - 1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var switchVehicle: some View {
        VStack(spacing: 0) {
            Rectangle().fill(ScreenKit.hairline).frame(height: 1)
            NavigationLink(value: MoreRoute.switchVehicle) {
                ScreenKit.CapsRow(symbol: "car.2.fill", tint: ScreenKit.mint, title: "Switch Vehicle",
                                  subtitle: vehicleName ?? "—")
            }
            .buttonStyle(.plain)
        }
    }

    private var footer: some View {
        Text("Volta · v\(AppInfo.version) · private")
            .font(.system(size: 12, weight: .medium)).tracking(1)
            .foregroundStyle(ScreenKit.secondary.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
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
