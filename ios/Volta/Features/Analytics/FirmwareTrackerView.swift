import SwiftUI

/// Timeline of installed software updates, newest first.
struct FirmwareTrackerView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @State private var state: Loadable<[FirmwareUpdate]> = .loading

    var body: some View {
        ScrollView {
            LoadableContent(state: state, retry: load) { updates in
                if updates.isEmpty {
                    EmptyState(systemImage: "cpu", title: "No updates recorded",
                               message: "Software updates appear here as TeslaMate sees them install.")
                        .padding(.top, 60)
                } else {
                    content(updates.sorted { $0.installedAt > $1.installedAt })
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.firmware")
        .screenKitPage("Firmware Tracker")
        .task(id: vehicleID) { await load() }
    }

    @ViewBuilder
    private func content(_ updates: [FirmwareUpdate]) -> some View {
        let current = updates[0]
        let gaps = zip(updates, updates.dropFirst()).map { $0.installedAt.timeIntervalSince($1.installedAt) / 86_400 }
        let avgGap = gaps.isEmpty ? nil : gaps.reduce(0, +) / Double(gaps.count)
        let lastYear = updates.filter { $0.installedAt > Date.now.addingTimeInterval(-365 * 86_400) }.count
        let daysOn = updates.indices.map { index in
            (index > 0 ? updates[index - 1].installedAt : Date.now).timeIntervalSince(updates[index].installedAt) / 86_400
        }
        let longest = max(daysOn.max() ?? 1, 1)

        VStack(alignment: .leading, spacing: 0) {
            AnalyticsHero(eyebrow: "Current software · \(VoltaFormat.relativeDate(current.installedAt))",
                          value: current.version, size: 50, identifier: "screen.firmware")
            Text("Installed \(current.installedAt.formatted(date: .long, time: .omitted))")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(AnalyticsStyle.secondary)
                .padding(.top, 6)
            AnalyticsStatStrip(items: [
                ("\(lastYear)", lastYear == 1 ? "Update · 1y" : "Updates · 1y"),
                (avgGap.map { VoltaFormat.number($0, digits: 0) } ?? "—", "Day cadence"),
                ("\(Int((daysOn.first ?? 0).rounded()))", "Days on"),
                ("\(updates.count)", updates.count == 1 ? "Version" : "Versions"),
            ])
            .padding(.top, 24)

            AnalyticsSectionHeader("Timeline", trailing: avgGap.map { "Every ~\(VoltaFormat.number($0, digits: 0)) days" })
                .padding(.top, AnalyticsStyle.sectionGap)
            VStack(spacing: 0) {
                ForEach(Array(updates.enumerated()), id: \.element.version) { index, update in
                    timelineRow(update, daysOn: daysOn[index], longest: longest,
                                isCurrent: index == 0, isLast: index == updates.count - 1)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .voltaCardBackground()
        }
    }

    private func timelineRow(_ update: FirmwareUpdate, daysOn: Double, longest: Double, isCurrent: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Circle()
                    .fill(isCurrent ? AnalyticsStyle.mint : Color.voltaBackground)
                    .overlay(Circle().strokeBorder(isCurrent ? AnalyticsStyle.mint : .white.opacity(0.22), lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .shadow(color: isCurrent ? AnalyticsStyle.mint.opacity(0.8) : .clear, radius: 5)
                    .padding(.top, 6)
                if !isLast {
                    Rectangle()
                        .fill(LinearGradient(colors: isCurrent ? [AnalyticsStyle.mint.opacity(0.6), .white.opacity(0.1)] : [.white.opacity(0.12), .white.opacity(0.08)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 1.5).frame(maxHeight: .infinity).padding(.vertical, 4)
                }
            }
            .frame(width: 12)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(update.version).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).monospacedDigit()
                    if isCurrent {
                        Text("Current").font(.system(size: 10, weight: .semibold)).tracking(1.2).textCase(.uppercase)
                            .foregroundStyle(AnalyticsStyle.mint)
                    }
                    Spacer(minLength: 8)
                    Text(update.installedAt.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(AnalyticsStyle.secondary)
                }
                HStack(spacing: 6) {
                    if let previous = update.previousVersion {
                        Text("from \(previous)")
                        Circle().fill(AnalyticsStyle.tertiary).frame(width: 2.5, height: 2.5)
                    }
                    Text(isCurrent ? "\(Int(daysOn.rounded())) days so far" : "\(Int(daysOn.rounded())) days on this version")
                }
                .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(AnalyticsStyle.tertiary)
                AnalyticsBar(fraction: daysOn / longest,
                             colors: isCurrent ? [AnalyticsStyle.mint, AnalyticsStyle.blue] : [.white.opacity(0.16), .white.opacity(0.3)],
                             height: 3)
                    .padding(.top, 2)
            }
            .padding(.bottom, isLast ? 0 : 22)
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do { state = .loaded(try await dataSource.firmware(vehicleID: vehicleID)) }
        catch is CancellationError {}
        catch { state = .failed(error.localizedDescription) }
    }
}

#Preview("Populated") {
    NavigationStack { FirmwareTrackerView() }.preferredColorScheme(.dark)
}

#Preview("Empty") {
    NavigationStack { FirmwareTrackerView() }
        .environment(\.dataSource, MockDataSource(empty: true))
        .preferredColorScheme(.dark)
}
