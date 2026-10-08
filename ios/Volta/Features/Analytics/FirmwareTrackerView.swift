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
        .screenKitPage("Firmware Tracker")
        .task(id: vehicleID) { await load() }
    }

    @ViewBuilder
    private func content(_ updates: [FirmwareUpdate]) -> some View {
        let current = updates[0]
        let gaps = zip(updates, updates.dropFirst()).map { $0.installedAt.timeIntervalSince($1.installedAt) / 86_400 }
        let avgGap = gaps.isEmpty ? nil : gaps.reduce(0, +) / Double(gaps.count)
        let lastYear = updates.filter { $0.installedAt > Date.now.addingTimeInterval(-365 * 86_400) }.count

        VStack(alignment: .leading, spacing: 18) {
            Card(padding: 20, tint: ScreenKit.mint) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Current software", trailing: VoltaFormat.relativeDate(current.installedAt))
                    ScreenKit.Numeral(value: current.version, size: 40)
                    Text("Installed \(current.installedAt.formatted(date: .long, time: .omitted))")
                        .font(.system(size: 14)).foregroundStyle(ScreenKit.secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ScreenKit.Metric(label: "Past year", value: "\(lastYear)", unit: lastYear == 1 ? "update" : "updates", symbol: "arrow.down.circle")
                ScreenKit.Metric(label: "Cadence", value: avgGap.map { VoltaFormat.number($0, digits: 0) } ?? "—", unit: "days",
                                 caption: "Average between updates", symbol: "calendar")
            }

            SectionLabel("Timeline").padding(.top, 10).padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(updates.enumerated()), id: \.element.version) { index, update in
                    let next = index > 0 ? updates[index - 1].installedAt : Date.now
                    timelineRow(update, daysOn: next.timeIntervalSince(update.installedAt) / 86_400,
                                isCurrent: index == 0, isLast: index == updates.count - 1)
                }
            }
        }
    }

    private func timelineRow(_ update: FirmwareUpdate, daysOn: Double, isCurrent: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(isCurrent ? ScreenKit.mint : Color.voltaRaised).frame(width: 14, height: 14)
                    if isCurrent { Circle().stroke(ScreenKit.mint.opacity(0.3), lineWidth: 6).frame(width: 14, height: 14) }
                }
                .padding(.top, 4)
                if !isLast {
                    Rectangle().fill(Color.voltaHairline).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(update.version).font(.system(size: 18, weight: .bold)).foregroundStyle(.white).monospacedDigit()
                    if isCurrent {
                        Text("CURRENT").font(.system(size: 10, weight: .bold)).tracking(1.2)
                            .foregroundStyle(ScreenKit.mint)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(ScreenKit.mint.opacity(0.14), in: .capsule)
                    }
                    Spacer()
                    Text(update.installedAt.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.system(size: 13)).foregroundStyle(ScreenKit.secondary)
                }
                HStack(spacing: 6) {
                    if let previous = update.previousVersion {
                        Text("from \(previous)")
                        Text("·")
                    }
                    Text(isCurrent ? "\(Int(daysOn.rounded())) days so far" : "\(Int(daysOn.rounded())) days on this version")
                }
                .font(.system(size: 13)).foregroundStyle(ScreenKit.secondary)
            }
            .padding(.bottom, isLast ? 0 : 26)
        }
        .padding(.horizontal, 4)
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
