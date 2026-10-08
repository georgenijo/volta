import SwiftUI

/// Root of the signed-in app: a floating Liquid Glass tab bar (Dashboard,
/// Charging, Drives, Idles) plus a separate circular "…" button for More.
///
/// History and More screens own their own `NavigationStack`s and are embedded
/// bare. Each tab is created the first time it's selected and then kept alive
/// so its navigation and scroll state survive tab switches.
struct MainShell: View {
    enum Tab: String, Hashable, CaseIterable {
        case dashboard, charging, drives, idles, more
    }

    @State private var selection: Tab = .dashboard
    @State private var visited: Set<Tab> = [.dashboard]

    var body: some View {
        ZStack(alignment: .bottom) {
            ForEach(Tab.allCases, id: \.self) { tab in
                if visited.contains(tab) {
                    screen(for: tab)
                        // Kept-alive tabs never disappear; tell them when they're hidden.
                        .environment(\.isActiveTab, selection == tab)
                        .opacity(selection == tab ? 1 : 0)
                        .allowsHitTesting(selection == tab)
                        .accessibilityHidden(selection != tab)
                }
            }
            ShellTabBar(selection: $selection)
        }
        .background(Color.voltaBackground.ignoresSafeArea())
        .onChange(of: selection) { _, new in visited.insert(new) }
        .tint(.voltaBlue)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func screen(for tab: Tab) -> some View {
        switch tab {
        case .dashboard: DashboardView()
        case .charging: ChargingHistoryView()
        case .drives: DrivesHistoryView()
        case .idles: IdlesHistoryView()
        case .more: MoreView()
        }
    }
}

extension EnvironmentValues {
    /// False while this screen's shell tab is hidden. MainShell keeps visited tabs
    /// mounted (only opacity changes), so `onDisappear` doesn't fire on tab switches;
    /// screens that must release state when hidden observe this instead.
    @Entry var isActiveTab: Bool = true
}

/// The floating bar: a glass capsule with four tabs (selected tab sits in a
/// darker inner capsule, icon in blue) and a detached glass "…" circle.
struct ShellTabBar: View {
    @Binding var selection: MainShell.Tab
    @Namespace private var ns

    private let items: [(MainShell.Tab, String, String)] = [
        (.dashboard, "car.fill", "Dashboard"),
        (.charging, "bolt.fill", "Charging"),
        (.drives, "steeringwheel", "Drives"),
        (.idles, "parkingsign", "Idles"),
    ]

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    ForEach(items, id: \.0) { tab, symbol, title in
                        tabButton(tab, symbol: symbol, title: title)
                    }
                }
                .padding(5)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button {
                    select(.more)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(selection == .more ? Color.voltaBlue : Color.voltaTextPrimary)
                        .frame(width: 66, height: 66)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("More")
                .accessibilityIdentifier("button.more")
                .accessibilityAddTraits(selection == .more ? .isSelected : [])
            }
        }
        .padding(.horizontal, VoltaSpacing.screen + 2)
        .padding(.bottom, 2)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func tabButton(_ tab: MainShell.Tab, symbol: String, title: String) -> some View {
        let selected = selection == tab
        return Button {
            select(tab)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(selected ? Color.voltaBlue : Color.voltaTextPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background {
                    if selected {
                        Capsule()
                            .fill(Color.black.opacity(0.35))
                            .matchedGeometryEffect(id: "selected", in: ns)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("tab.\(tab.rawValue)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func select(_ tab: MainShell.Tab) {
        withAnimation(.snappy(duration: 0.3)) { selection = tab }
    }
}

#Preview("Shell") {
    MainShell()
        .environment(\.dataSource, MockDataSource())
}

#Preview("Shell – empty") {
    MainShell()
        .environment(\.dataSource, MockDataSource(empty: true))
}
