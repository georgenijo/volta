import SwiftUI

/// Root of the signed-in app: a system tab view with Dashboard, Charging,
/// Drives, Parked and More.
///
/// The system owns the bar. On iPhone Duo it moves the tabs to the side on
/// the outer display and on the inner display in landscape; everywhere else
/// it is the floating Liquid Glass bar at the bottom. Screens own their own
/// `NavigationStack`s, and a tab is built the first time it is selected and
/// then kept, so its navigation and scroll state survive tab switches.
struct MainShell: View {
    enum Tab: String, Hashable, CaseIterable {
        case dashboard, charging, drives, idles, more

        var title: String {
            switch self {
            case .dashboard: "Dashboard"
            case .charging: "Charging"
            case .drives: "Drives"
            case .idles: "Parked"
            case .more: "More"
            }
        }

        /// The ellipsis is left to the system's toolbar overflow menu.
        var symbol: String {
            switch self {
            case .dashboard: "car.fill"
            case .charging: "bolt.fill"
            case .drives: "steeringwheel"
            case .idles: "parkingsign"
            case .more: "square.grid.2x2.fill"
            }
        }
    }

    @State private var selection: Tab = MainShell.initialTab
    @Environment(AppModel.self) private var app: AppModel?

    /// Screenshot aid (DEBUG): `-demoTab charging` opens on that tab.
    private static var initialTab: Tab {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "demoTab"), let tab = Tab(rawValue: raw) { return tab }
        #endif
        return .dashboard
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Tab.allCases, id: \.self) { tab in
                SwiftUI.Tab(tab.title, systemImage: tab.symbol, value: tab) {
                    screen(for: tab)
                        // A kept tab does not disappear when another is selected.
                        .environment(\.isActiveTab, selection == tab)
                        // Each tab learns whether the system put the bars on the side.
                        .readsBarsOnSide()
                }
                .accessibilityIdentifier("tab.\(tab.rawValue)")
            }
        }
        .tint(.voltaBlue)
        // The lock control's request opens Controls on the Dashboard.
        .onChange(of: app?.controlsPresentationRequested == true, initial: true) { _, requested in
            selection = ControlsRouting.shellTab(requested: requested, current: selection)
        }
        .voltaFeedback(.selection, trigger: selection)
        // One place for command haptics, whichever screen sent the command.
        .voltaFeedback(trigger: CommandPulse(VehicleCommandLog.shared.entries.last)) { old, new in
            CommandPulse.feedback(from: old, to: new)
        }
    }

    @ViewBuilder
    private func screen(for tab: Tab) -> some View {
        switch tab {
        case .dashboard: DashboardView().followsSystemTextSize()
        case .charging: ChargingHistoryView()
        case .drives: DrivesHistoryView()
        case .idles: IdlesHistoryView()
        case .more: MoreView()
        }
    }
}

extension EnvironmentValues {
    /// False while this screen's shell tab is not the selected one. The tab
    /// view keeps visited tabs alive, so screens that must release state when
    /// hidden observe this instead of `onDisappear`.
    @Entry var isActiveTab: Bool = true
}

#Preview("Shell") {
    MainShell()
        .environment(\.dataSource, MockDataSource())
}

#Preview("Shell – empty") {
    MainShell()
        .environment(\.dataSource, MockDataSource(empty: true))
}

/// The newest command and its outcome, as a haptic trigger: a tap as it
/// goes out, success once the server or car takes it, an error if it fails.
struct CommandPulse: Equatable {
    var id: UUID?
    var outcome: VehicleCommandLog.Outcome?

    init(_ entry: VehicleCommandLog.Entry?) {
        id = entry?.id
        outcome = entry?.outcome
    }

    init(id: UUID?, outcome: VehicleCommandLog.Outcome?) {
        self.id = id
        self.outcome = outcome
    }

    static func feedback(from old: CommandPulse, to new: CommandPulse) -> VoltaFeedback? {
        guard new.id != nil, new != old else { return nil }
        switch new.outcome {
        case .sending?: return .commandSent
        // Once: an accepted command later confirmed by the car doesn't buzz twice.
        case .accepted?, .simulated?: return .commandConfirmed
        case .confirmed?: return old.id == new.id && old.outcome == .accepted ? nil : .commandConfirmed
        case .failed?: return .commandFailed
        case .unknown?, nil: return nil
        }
    }
}
