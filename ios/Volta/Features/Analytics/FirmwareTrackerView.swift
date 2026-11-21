import SwiftUI

/// Timeline of installed software updates, newest first.
struct FirmwareTrackerView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @State private var state: Loadable<[FirmwareUpdate]> = .loading

    var body: some View {
        // Wide: current version and cadence beside the timeline.
        ScreenKit.Page(scroll: "firmware", splits: !sortedUpdates.isEmpty) {
            LoadableContent(state: state, retry: load, placeholder: Self.placeholder, errorTitle: "Couldn't load software history") { updates in
                if updates.isEmpty {
                    EmptyState(systemImage: "cpu", title: "No updates recorded",
                               message: "Software updates appear here as TeslaMate sees them install. The next one the car installs starts the timeline.")
                        .padding(.top, 60)
                } else {
                    summary(sortedUpdates)
                }
            }
        } secondary: {
            if !sortedUpdates.isEmpty { timeline(sortedUpdates) }
        }
        .screenKitPage("Firmware tracker", screen: "firmware")
        .task(id: vehicleID) { await load() }
    }

    /// Newest first.
    private var sortedUpdates: [FirmwareUpdate] {
        (state.value ?? []).sorted { $0.installedAt > $1.installedAt }
    }

    @ViewBuilder
    private func summary(_ updates: [FirmwareUpdate]) -> some View {
        let current = updates[0]
        let gaps = zip(updates, updates.dropFirst()).map { $0.installedAt.timeIntervalSince($1.installedAt) / 86_400 }
        let avgGap = gaps.isEmpty ? nil : gaps.reduce(0, +) / Double(gaps.count)
        let lastYear = updates.filter { $0.installedAt > Date.now.addingTimeInterval(-365 * 86_400) }.count

        VStack(alignment: .leading, spacing: 18) {
            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Current software", trailing: VoltaFormat.relativeDate(current.installedAt))
                    ScreenKit.Numeral(value: current.version, size: 40)
                    Text("Installed \(current.installedAt.formatted(date: .long, time: .omitted))")
                        .font(.subheadline).foregroundStyle(ScreenKit.secondary)
                }
            }
            .voltaFocusIn(0)

            ScreenKit.MetricGroup {
                ScreenKit.Metric(label: "Past year", value: "\(lastYear)", unit: lastYear == 1 ? "update" : "updates", symbol: "arrow.down.circle")
                ScreenKit.Metric(label: "Time between updates", value: avgGap.map { VoltaFormat.number($0, digits: 0) } ?? "—", unit: "days",
                                 caption: "On average", symbol: "calendar")
            }
            .voltaFocusIn(1)
        }
    }

    private func timeline(_ updates: [FirmwareUpdate]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionLabel("Timeline").padding(.top, 10).padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(updates.enumerated()), id: \.element.version) { index, update in
                    let next = index > 0 ? updates[index - 1].installedAt : Date.now
                    timelineRow(update, daysOn: next.timeIntervalSince(update.installedAt) / 86_400,
                                isCurrent: index == 0, isLast: index == updates.count - 1)
                        .voltaFocusIn(index)
                }
            }
        }
    }

    private func timelineRow(_ update: FirmwareUpdate, daysOn: Double, isCurrent: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                // The current version is the live one: blue, with no halo.
                Circle().fill(isCurrent ? ScreenKit.blue : Color.voltaRaised).frame(width: 14, height: 14)
                    .padding(.top, 4)
                if !isLast {
                    Rectangle().fill(Color.voltaHairline).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(update.version).font(.headline).foregroundStyle(.voltaTextPrimary).monospacedDigit()
                    if isCurrent {
                        Text("Current").font(.caption.weight(.semibold))
                            .foregroundStyle(Color.voltaBlueText)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(ScreenKit.blue.opacity(0.14), in: .capsule)
                    }
                    Spacer()
                    Text(update.installedAt.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.footnote).foregroundStyle(ScreenKit.secondary)
                }
                HStack(spacing: 6) {
                    if let previous = update.previousVersion {
                        Text("From \(previous)")
                        Text("·")
                    }
                    Text(isCurrent ? "\(Int(daysOn.rounded())) days so far" : "\(Int(daysOn.rounded())) days on this version")
                }
                .font(.footnote).foregroundStyle(ScreenKit.secondary)
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

extension FirmwareTrackerView {
    /// Sample timeline for the loading skeleton.
    static let placeholder: [FirmwareUpdate] = [
        FirmwareUpdate(version: "2026.20.1", installedAt: .now.addingTimeInterval(-20 * 86_400), previousVersion: "2026.14.3"),
        FirmwareUpdate(version: "2026.14.3", installedAt: .now.addingTimeInterval(-60 * 86_400), previousVersion: nil),
    ]
}

#Preview("Populated") {
    NavigationStack { FirmwareTrackerView() }
}

#Preview("Empty") {
    NavigationStack { FirmwareTrackerView() }
        .environment(\.dataSource, MockDataSource(empty: true))
}
