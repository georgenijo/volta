import SwiftUI

/// Loads this month's and last month's sessions for `ChargingRecap`. Every
/// `load` takes a new generation; only the latest one's result lands, so a
/// slow earlier request can never overwrite a newer one.
@MainActor @Observable
final class ChargingRecapModel {
    struct Key: Hashable {
        var vehicleID: Int
        /// Start of the current month: a new month loads again.
        var month: Date
    }

    private(set) var state: Loadable<ChargingRecap> = .loading
    private(set) var key: Key?
    private var loadedAt: Date?
    private var generation = 0
    /// How long a reappearing tab trusts its recap before loading it again.
    static let revalidateAfter: TimeInterval = 60

    /// Loads unless the recap for this vehicle and month loaded under a minute ago.
    func loadIfNeeded(source: any VoltaDataSource, vehicleID: Int, now: Date = .now, calendar: Calendar = .current) async {
        let wanted = Key(vehicleID: vehicleID, month: ChargingRecap.month(containing: now, calendar: calendar).start)
        if wanted == key, state.value != nil, let loadedAt, now.timeIntervalSince(loadedAt) < Self.revalidateAfter { return }
        await load(source: source, vehicleID: vehicleID, now: now, calendar: calendar)
    }

    /// True when a recap landed. A failed refresh keeps a recap already shown
    /// for the same vehicle and month; the list reports the failure.
    @discardableResult
    func load(source: any VoltaDataSource, vehicleID: Int, now: Date = .now, calendar: Calendar = .current) async -> Bool {
        generation += 1
        let mine = generation
        let wanted = Key(vehicleID: vehicleID, month: ChargingRecap.month(containing: now, calendar: calendar).start)
        if wanted != key || state.value == nil { state = .loading }
        do {
            let recap = try await Self.fetch(source: source, vehicleID: vehicleID, now: now, calendar: calendar)
            guard !Task.isCancelled, mine == generation else { return false }
            state = .loaded(recap)
            key = wanted
            loadedAt = now
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard !Task.isCancelled, mine == generation else { return false }
            if wanted != key || state.value == nil {
                state = .failed(error.localizedDescription)
                key = wanted
            }
            return false
        }
    }

    /// Every page from the start of last month, with the paging helper
    /// Charging Insights uses.
    nonisolated static func fetch(source: any VoltaDataSource, vehicleID: Int, now: Date,
                                  calendar: Calendar) async throws -> ChargingRecap {
        let range = ChargingRecap.range(now: now, calendar: calendar)
        let result = try await fetchAllPages { try await source.charges(vehicleID: vehicleID, range: range, cursor: $0) }
        return ChargingRecap(charges: result.items, now: now, calendar: calendar, isComplete: result.isComplete)
    }
}

/// "November so far": charges, energy added, cost and home share for the
/// month, each with its change since last month. Tapping it opens Charging
/// Insights.
struct ChargingRecapCard: View {
    var state: Loadable<ChargingRecap>
    var retry: () async -> Void
    var open: () -> Void
    var calendar: Calendar = .current

    var body: some View {
        switch state {
        case .loading:
            content(ChargingRecap.sample(calendar: calendar))
                .voltaSkeleton(true)
        case .failed(let message):
            ErrorState(title: "Couldn't load this month's charging", message: message, retry: retry)
                .padding(.vertical, VoltaSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .driveSurface(radius: 22)
        case .loaded(let recap):
            Button(action: open) { content(recap) }
                .buttonStyle(VoltaPressStyle())
                .accessibilityHint("Opens charging insights")
        }
    }

    private func content(_ recap: ChargingRecap) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(recap)
            if recap.current.isEmpty {
                RecapEmptyLine(recap: recap, calendar: calendar)
            } else {
                headline(recap)
                figures(recap)
                let notes = recap.notes(calendar: calendar)
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(HistoryTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .driveSurface(radius: 22)
        .contentShape(.rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card.charging.recap")
    }

    private func header(_ recap: ChargingRecap) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(recap.title(calendar: calendar))
                .font(.system(.subheadline, weight: .semibold)).foregroundStyle(Color.voltaTextPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if !recap.current.isEmpty, !recap.previous.isEmpty, recap.isComplete {
                Text(recap.comparison(calendar: calendar)).font(.voltaLabel).foregroundStyle(HistoryTheme.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(HistoryTheme.tertiary)
                .accessibilityHidden(true)
        }
    }

    /// The one large reading: how many times the car charged.
    private func headline(_ recap: ChargingRecap) -> some View {
        let count = recap.current.sessions
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            RollingNumber(value: Double(count)) { "\(Int($0.rounded()))" }
                .font(.system(size: 44, weight: .heavy))
                .foregroundStyle(Color.voltaTextPrimary)
            Text(count == 1 ? "charge" : "charges")
                .font(.system(size: 15)).foregroundStyle(HistoryTheme.secondary)
            Spacer(minLength: 8)
            if let change = recap.sessionsChange {
                ChangeText(text: ChargingRecap.changeText(change))
            }
        }
    }

    private func figures(_ recap: ChargingRecap) -> some View {
        let month = recap.current
        return HStack(alignment: .top, spacing: 12) {
            RecapFigure(label: "Energy added", systemImage: "bolt.fill", tint: HistoryTheme.green,
                        value: month.energyKwh, unit: "kWh",
                        change: recap.energyChange.map(ChargingRecap.energyChangeText)) {
                VoltaFormat.number($0, digits: $0 >= 100 ? 0 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RecapFigure(label: "Cost", systemImage: "creditcard.fill", tint: HistoryTheme.secondary,
                        value: month.cost, unit: nil,
                        change: recap.costChange.flatMap { change in
                            month.currency.map { ChargingRecap.costChangeText(change, currency: $0) }
                        }) { [currency = month.currency ?? "USD"] in
                VoltaFormat.money($0, currency: currency)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RecapFigure(label: "At home", systemImage: "house.fill", tint: HistoryTheme.secondary,
                        value: month.homePercent.map(Double.init), unit: nil,
                        change: recap.homeShareChange.map(ChargingRecap.pointsChangeText)) {
                "\(Int($0.rounded()))%"
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A labelled figure that rolls in, its change underneath; unknown is an em dash.
private struct RecapFigure: View {
    var label: String
    var systemImage: String
    var tint: Color
    var value: Double?
    var unit: String?
    var change: String?
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(label).font(.voltaLabel).foregroundStyle(HistoryTheme.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let value {
                    RollingNumber(value: value, format: format)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.voltaTextPrimary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if let unit { Text(unit).font(.system(size: 12)).foregroundStyle(HistoryTheme.secondary) }
                } else {
                    Text("—").font(.system(size: 20, weight: .bold)).foregroundStyle(HistoryTheme.secondary)
                        .accessibilityLabel("Unknown")
                }
            }
            if let change { ChangeText(text: change) }
        }
    }
}

/// A change since last month, in ink: up and down are neither good nor bad.
private struct ChangeText: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            .foregroundStyle(HistoryTheme.secondary)
            .lineLimit(1).minimumScaleFactor(0.8)
            .voltaRolling(text)
    }
}

/// No charges yet this month: says so, and what last month held.
private struct RecapEmptyLine: View {
    var recap: ChargingRecap
    var calendar: Calendar
    @State private var appeared = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let month = ChargingRecap.monthName(recap.current.interval.start, calendar: calendar)
        let last = ChargingRecap.monthName(recap.previous.interval.start, calendar: calendar)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 22, weight: .light)).foregroundStyle(HistoryTheme.tertiary)
                .symbolEffect(.bounce, value: appeared)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("No charges yet in \(month)")
                    .font(.system(.body, weight: .semibold)).foregroundStyle(Color.voltaTextPrimary)
                Text(recap.previous.isEmpty
                     ? "This month's charges will add up here."
                     : "\(last) had \(ChargingInsights.sessions(recap.previous.sessions)). This month's will add up here.")
                    .font(.subheadline).foregroundStyle(HistoryTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { if !reduceMotion { appeared += 1 } }
    }
}

extension ChargingRecap {
    /// Placeholder figures for the loading skeleton (synthetic).
    static func sample(now: Date = .now, calendar: Calendar) -> ChargingRecap {
        let start = month(containing: now, calendar: calendar).start
        let charges = (0..<6).map { i in
            ChargeSummary(id: -100 - i, start: start.addingTimeInterval(Double(i) * 3600), end: nil, address: nil,
                          placeName: i < 4 ? "Home" : nil, energyAddedKwh: 30, energyUsedKwh: nil, startBatteryLevel: nil,
                          endBatteryLevel: nil, durationMin: 60, maxPowerKw: nil, fastCharger: false, cost: 6,
                          currency: "USD", outsideTempAvgC: nil)
        }
        return ChargingRecap(charges: charges, now: now, calendar: calendar)
    }
}

#Preview("Recap") {
    let calendar = Calendar.current
    VStack(spacing: 16) {
        ChargingRecapCard(state: .loaded(.sample(calendar: calendar)), retry: {}, open: {})
        ChargingRecapCard(state: .loaded(ChargingRecap(charges: [], now: .now, calendar: calendar)), retry: {}, open: {})
        ChargingRecapCard(state: .loading, retry: {}, open: {})
    }
    .padding()
    .historyScreenBackground()
}
