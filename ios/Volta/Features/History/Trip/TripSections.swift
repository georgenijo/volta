import SwiftUI

// MARK: - Trip chrome

/// Section title for the trip screen: same voice as the drives list's day headers.
struct TripSectionHeader: View {
    var title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .foregroundStyle(HistoryTheme.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Grouped trip data on the lit drive surface.
    func tripPanel(padding: CGFloat = 18) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .driveSurface()
    }

    /// 10–11 pt uppercase caption in the tertiary tone.
    func tripCaption(_ color: Color = HistoryTheme.tertiary, size: CGFloat = 10) -> some View {
        self.font(.system(size: size, weight: .semibold)).tracking(1.1).textCase(.uppercase).foregroundStyle(color)
    }
}

/// Small glowing dot used as a light accent beside titles and endpoints.
struct TripGlowDot: View {
    var color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .shadow(color: color.opacity(0.7), radius: size * 0.6)
    }
}

// MARK: - Hero

/// Open hero: eyebrow, expanded distance numeral, the drive's score dial, and
/// the start → end itinerary with times and battery.
struct TripHero: View {
    var summary: DriveSummary
    var units: UnitPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(eyebrow).voltaLabelStyle(color: HistoryTheme.tertiary).lineLimit(1).minimumScaleFactor(0.8)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(VoltaFormat.number(units.distanceValue(km: summary.distanceKm)))
                            .font(.system(size: 84, weight: .bold)).fontWidth(.expanded).tracking(-2)
                            .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.45)
                        Text(units.distanceUnit).font(.system(size: 20, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("screen.drive-detail")
                Spacer(minLength: 0)
                ScoreDial(score: summary.efficiencyScore, size: 86, caption: "Score").padding(.trailing, 4)
            }
            itinerary
        }
    }

    private var eyebrow: String {
        summary.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var itinerary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 0) {
                    TripGlowDot(color: HistoryTheme.mint).padding(.top, 7)
                    Rectangle()
                        .fill(LinearGradient(colors: [HistoryTheme.mint.opacity(0.6), HistoryTheme.blue.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 1.5).frame(maxHeight: .infinity).padding(.top, 5)
                }
                .frame(width: 8)
                stop(summary.startCity ?? summary.startAddress, time: summary.start, level: summary.startBatteryLevel)
                    .padding(.bottom, 20)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 0) {
                    Rectangle().fill(HistoryTheme.blue.opacity(0.35)).frame(width: 1.5, height: 2)
                    TripGlowDot(color: HistoryTheme.blue).padding(.top, 5)
                }
                .frame(width: 8)
                stop(summary.endCity ?? summary.endAddress, time: summary.end, level: summary.endBatteryLevel)
            }
        }
    }

    private func stop(_ address: String?, time: Date?, level: Int?) -> some View {
        let place = TripPlace(address)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(place.primary)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(address == nil ? HistoryTheme.secondary : .white)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if let secondary = place.secondary {
                    Text(secondary).font(.system(size: 12, weight: .medium)).foregroundStyle(HistoryTheme.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(time.map { $0.formatted(.dateTime.hour().minute()) } ?? "Now")
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.9))
                HStack(spacing: 5) {
                    if let level {
                        Image(systemName: TripPlace.batterySymbol(level)).font(.system(size: 11, weight: .medium))
                        Text("\(level)%")
                    } else {
                        Text("—")
                    }
                }
                .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Splits a recorded address into a short primary name and the remainder.
struct TripPlace: Equatable {
    var primary: String
    var secondary: String?

    init(_ address: String?) {
        let parts = (address ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        primary = parts.first ?? "Unknown place"
        secondary = parts.count > 1 ? parts.dropFirst().joined(separator: ", ") : nil
    }

    static func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

// MARK: - Stats row

struct TripStatsRow: View {
    var summary: DriveSummary
    var units: UnitPreferences
    var regen: TripEstimate?
    var maxSpeed: TripMetric?

    var body: some View {
        let speedUnit = units.distance == .miles ? "mph" : "km/h"
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 0) {
                stat(VoltaFormat.duration(summary.durationMin), "Driving", first: true)
                divider
                stat(summary.energyUsedKwh.map { VoltaFormat.number($0) } ?? "—", "kWh")
                divider
                stat(summary.efficiencyWhPerKm.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) } ?? "—", units.efficiencyUnit)
                divider
                stat(summary.avgSpeedKph.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—", "\(speedUnit) avg")
            }
            HStack(spacing: 8) {
                metric("arrow.triangle.2.circlepath", "Regen " + regenLine)
                dot
                metric("gauge.with.dots.needle.67percent", "Max " + maxText + (maxText == "—" ? "" : " \(speedUnit)"))
                Spacer(minLength: 0)
            }
        }
    }

    private var regenLine: String {
        guard case .estimate(let v, let coverage) = regen else { return "—" }
        return "≈\(VoltaFormat.number(v)) kWh" + (regen?.isComplete == true ? "" : " · " + TripAnalysis.percent(coverage) + " sampled")
    }

    private var divider: some View { Rectangle().fill(HistoryTheme.hairline).frame(width: 1, height: 28) }

    private var dot: some View { Circle().fill(HistoryTheme.tertiary).frame(width: 2.5, height: 2.5) }

    private func stat(_ value: String, _ caption: String, first: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                .foregroundStyle(value == "—" ? HistoryTheme.secondary : .white).lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).tripCaption().lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, first ? 0 : 12)
        .accessibilityElement(children: .combine)
    }

    private func metric(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
            Text(text).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.78))
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    /// Regen is a sample-derived estimate (see `TripAnalysis.regen`): always
    /// "≈", never a measurement or a bound, with the power coverage when partial.
    static func regenText(_ regen: TripEstimate?) -> String {
        switch regen {
        case .estimate(let v, let coverage):
            "≈" + VoltaFormat.number(v) + (regen?.isComplete == true ? "" : " · " + TripAnalysis.percent(coverage))
        case .unavailable, nil: "—"
        }
    }

    /// The details-list wording of the same estimate.
    static func regenDetail(_ regen: TripEstimate?) -> String {
        switch regen {
        case .estimate(let v, let coverage):
            let note = regen?.isComplete == true
                ? "estimated from samples"
                : "partial estimate · power sampled for \(TripAnalysis.percent(coverage)) of the trip"
            return "≈ \(VoltaFormat.number(v, digits: 2)) kWh (\(note))"
        case .unavailable(let reason): return "— · \(reason)"
        case nil: return "—"
        }
    }

    private var maxText: String {
        switch maxSpeed {
        case .value(let v): VoltaFormat.number(units.distanceValue(km: v), digits: 0)
        case .atLeast(let v): "≥" + VoltaFormat.number(units.distanceValue(km: v), digits: 0)
        case .unavailable, nil: "—"
        }
    }

}

// MARK: - Sampling disclosure

/// Plain-language account of what was recorded. Shown above the charts
/// whenever the trip is not densely sampled.
struct TripSamplingNote: View {
    var timeline: TripTimeline

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: timeline.quality == .partial ? "waveform.path.ecg" : "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HistoryTheme.amber)
                .shadow(color: HistoryTheme.amber.opacity(0.5), radius: 4)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(TripSamplingNote.title(timeline))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(TripSamplingNote.detail(timeline))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HistoryTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tripPanel(padding: 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trip.sampling")
    }

    static func title(_ t: TripTimeline) -> String {
        let samples = "\(t.points.count) distinct sample\(t.points.count == 1 ? "" : "s")"
        switch t.quality {
        case .dense: return "Densely recorded · \(samples)"
        case .partial: return "Partly recorded · \(samples) over \(VoltaFormat.duration(t.totalMinutes))"
        case .sparse: return "Sparse recording · \(samples) over \(VoltaFormat.duration(t.totalMinutes))"
        case .none: return "No positions recorded"
        }
    }

    static func detail(_ t: TripTimeline) -> String {
        var parts: [String] = []
        if t.duplicatesRemoved > 0 || t.conflictingRowsDropped > 0 {
            parts.append("\(t.rawCount.formatted()) rows received; \(t.duplicatesRemoved.formatted()) exact repeats removed.")
        }
        if t.conflictingTimestamps > 0 {
            parts.append("\(t.conflictingTimestamps) timestamp\(t.conflictingTimestamps == 1 ? "" : "s") had conflicting rows; one row was kept by a fixed rule.")
        }
        parts.append("\(TripAnalysis.percent(t.coverage)) of the trip lies within \(Int(TripTimeline.gapThreshold / 60)) min of a sample.")
        if t.gapCount > 0 || t.longestGap > 0 {
            parts.append("Lines are not drawn across gaps (longest \(VoltaFormat.duration(t.longestGap / 60))); dashed map lines only join samples and are not the driven path.")
        }
        if t.quality != .dense { parts.append("Regen and smoothness need denser samples.") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Cost

struct TripCostCard: View {
    var energyKwh: Double?
    var rate: TripRate?
    /// Outcome of the previous-charge lookup; nil while it runs.
    var lookup: TripRateLookup?
    var editable: Bool
    /// Where the energy figure came from, shown under the cost source.
    var note: String? = nil
    var onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trip cost").tripCaption()
                    if let rate, let cost = rate.cost(energyKwh: energyKwh) {
                        Text(VoltaFormat.money(cost, currency: rate.currency))
                            .font(.system(size: 30, weight: .bold)).fontWidth(.expanded).tracking(-0.8).monospacedDigit()
                            .foregroundStyle(.white)
                            .accessibilityIdentifier("trip.cost")
                    } else {
                        Text("Cost unknown")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(HistoryTheme.secondary)
                            .accessibilityIdentifier("trip.cost")
                    }
                }
                Spacer(minLength: 8)
                if let rate {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(TripCostCard.rateText(rate))
                            .font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.9))
                        Text("per kWh").tripCaption()
                    }
                }
            }
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 4) {
                if let rate, rate.cost(energyKwh: energyKwh) != nil {
                    Text(sourceText(rate))
                } else {
                    Text(TripCostCard.unknownReason(energyKwh: energyKwh, rate: rate, lookup: lookup))
                        .accessibilityIdentifier("trip.cost.reason")
                }
                if let note { Text(note) }
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            if editable {
                Button(rate?.source == .manual ? "Edit rate" : "Set your rate", action: onEdit)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HistoryTheme.blue)
                    .accessibilityIdentifier("trip.rate.edit")
            }
        }
        .tripPanel()
    }

    /// Why there's no cost. Never claims "no priced charge" unless the whole
    /// history before the trip was checked.
    static func unknownReason(energyKwh: Double?, rate: TripRate?, lookup: TripRateLookup?) -> String {
        if rate != nil || energyKwh == nil { return "Energy used was not recorded for this trip." }
        switch lookup {
        case nil: return "Looking for the last priced charge before this trip…"
        case .found: return "Energy used was not recorded for this trip."
        case .noPricedCharge: return "No charge before this trip has a recorded cost, and no rate is set."
        case .currencyUnknown(let date):
            return "The last priced charge (\(date.formatted(date: .abbreviated, time: .omitted))) has no recorded currency. Set your rate to cost this trip."
        case .incomplete(let reason):
            return "\(reason); the last priced charge wasn't found. Set your rate to cost this trip."
        }
    }

    static func rateText(_ rate: TripRate) -> String {
        rate.perKwh.formatted(.currency(code: rate.currency).precision(.fractionLength(3)))
    }

    private func sourceText(_ rate: TripRate) -> String {
        switch rate.source {
        case .manual:
            return "Estimated · energy used × Settings electricity rate (USD)."
        case .chargeAverage:
            return "Estimated · energy used × energy-weighted average of priced TeslaMate charges before this drive."
        case .previousCharge(let place, let date):
            let where_ = place.map { " at \($0)" } ?? ""
            let day = date.formatted(date: .abbreviated, time: .omitted)
            if rate.perKwh == 0 { return "The last charge before this trip\(where_), \(day), was free." }
            return "Energy used × rate of the last priced charge\(where_), \(day)."
        }
    }
}

/// Sheet for the device-local manual rate.
struct TripRateEditor: View {
    var initial: TripRate?
    var defaultCurrency: String
    var onSave: (TripRate?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rateText = ""
    @State private var currency = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Price per kWh", text: $rateText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("trip.rate.value")
                    TextField("Currency (e.g. USD)", text: $currency)
                        .accessibilityIdentifier("trip.rate.currency")
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Enter 0 if your charging is free. Stored only on this device for this server and vehicle; used instead of the previous charge's price.")
                }
                if initial?.source == .manual {
                    Section {
                        Button("Remove rate", role: .destructive) { onSave(nil); dismiss() }
                    }
                }
            }
            .navigationTitle("Electricity rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(parsed); dismiss() }.disabled(parsed == nil)
                        .accessibilityIdentifier("trip.rate.save")
                }
            }
        }
        .onAppear {
            if let initial { rateText = String(initial.perKwh); currency = initial.currency } else { currency = defaultCurrency }
        }
    }

    private var parsed: TripRate? {
        let normalized = rateText.replacingOccurrences(of: ",", with: ".")
        return TripRate(stored: "\(normalized)|\(currency.trimmingCharacters(in: .whitespaces))")
    }
}

// MARK: - Score

/// Drive detail shows the server's `scoreBreakdown` first; components it does
/// not know are filled from on-device analysis, and the rest are drawn as "—".
extension DriveScoreBreakdown {
    static func resolved(server: DriveScoreBreakdown?, local result: SmoothnessScore.Result?) -> DriveScoreBreakdown {
        (server ?? DriveScoreBreakdown()).filling(from: DriveScoreBreakdown(local: result))
    }

    /// What today's on-device Volta v1 smoothness analysis can supply.
    init(local result: SmoothnessScore.Result?) {
        guard case .score(let s) = result else { self.init(); return }
        let acceleration = s.parts.first { $0.name == "Acceleration" }.map { Int($0.score.rounded()) }
        self.init(acceleration: acceleration, smoothness: s.score)
    }

    var components: [(title: String, value: Int?)] {
        [("Efficiency", efficiency), ("Acceleration", acceleration), ("Speed", speed), ("Smoothness", smoothness)]
    }
}

/// One component: name and value over a thin lit bar.
struct ScoreBreakdownRow: View {
    var title: String
    var value: Int?

    var body: some View {
        let tint = DriveScoreBand.tint(value)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                Spacer(minLength: 6)
                Text(value.map(String.init) ?? "—")
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(value == nil ? HistoryTheme.tertiary : .white)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.07))
                    if let value, value > 0 {
                        Capsule()
                            .fill(LinearGradient(colors: [tint.opacity(0.35), tint], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, geo.size.width * Double(value) / 100))
                            .shadow(color: tint.opacity(0.55), radius: 3)
                    }
                }
            }
            .frame(height: 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value.map { "\($0) of 100" } ?? "not reported")")
    }
}

/// Drive score: the large dial, the four-part breakdown, then Volta's own
/// smoothness measure with its formula.
struct TripScoreCard: View {
    var score: Int?
    var breakdown: DriveScoreBreakdown
    /// Volta v1 smoothness; nil while the drive loads.
    var result: SmoothnessScore.Result?
    @State private var showsFormula = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 22) {
                ScoreDial(score: score, size: 112, caption: "of 100")
                VStack(spacing: 13) {
                    ForEach(breakdown.components, id: \.title) { ScoreBreakdownRow(title: $0.title, value: $0.value) }
                }
            }
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
            smoothness
            DisclosureGroup(isExpanded: $showsFormula) {
                Text(TripScoreCard.formula)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HistoryTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } label: {
                Text("How smoothness is calculated").font(.system(size: 13, weight: .semibold)).foregroundStyle(HistoryTheme.blue)
            }
            .tint(HistoryTheme.blue)
        }
        .tripPanel()
    }

    @ViewBuilder private var smoothness: some View {
        switch result {
        case .score(let s):
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On-device smoothness · Volta v1").tripCaption()
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(s.score)").font(.system(size: 24, weight: .bold)).fontWidth(.expanded).monospacedDigit().foregroundStyle(.white)
                        Text(s.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(DriveScoreBand.tint(s.score))
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    smallStat("\(s.hardEvents)", "Hard")
                    Rectangle().fill(HistoryTheme.hairline).frame(width: 1, height: 26).padding(.horizontal, 12)
                    smallStat("\(VoltaFormat.number(s.maxG, digits: 2))g", "Max")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("trip.score")
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Text("On-device smoothness · Volta v1").tripCaption()
                Text("Unavailable")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(HistoryTheme.secondary)
                    .accessibilityIdentifier("trip.score")
                Text(reason).font(.system(size: 12, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case nil:
            VStack(alignment: .leading, spacing: 4) {
                Text("On-device smoothness · Volta v1").tripCaption()
                Text("—").font(.system(size: 17, weight: .semibold)).foregroundStyle(HistoryTheme.secondary)
            }
        }
    }

    private func smallStat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
            Text(caption).tripCaption()
        }
    }

    static let formula = """
    Volta's own measure, not comparable to scores in other apps. From recorded speed (and power when present), \
    over intervals of at most 6 s while moving above 5 km/h. Acceleration: share of accelerating time at ≤ 2.0 m/s². \
    Braking: share of braking time at ≤ 2.5 m/s². Power: share of time with power changing ≤ 15 kW/s. \
    Score is the mean of the available parts. Hard events are runs at ≥ 0.3 g. Needs ≥ 70% of the trip sampled \
    and ≥ 120 intervals. Speed limits and road type are not known, so they are not scored.
    """
}

// MARK: - Not recorded

/// Wattly-style sections whose inputs the current API doesn't carry. Listed so
/// their absence is explicit instead of drawn as empty charts.
struct TripUnrecordedCard: View {
    var outsideAvg: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Not recorded yet").tripCaption()
            row("Temperatures", "Cabin and outside traces need per-sample temperatures." + (outsideAvg.map { " Trip outside average: \($0)." } ?? ""))
            row("Energy remaining", "Needs per-sample energy remaining or usable battery level.")
            row("Range efficiency", "Needs rated range at the start and end of the trip.")
        }
        .tripPanel()
        .accessibilityIdentifier("trip.unrecorded")
    }

    private func row(_ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(.white.opacity(0.18)).frame(width: 5, height: 5).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Details

struct TripDetailsList: View {
    var rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Rectangle().fill(HistoryTheme.hairline).frame(height: 1) }
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0).font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                    Spacer(minLength: 12)
                    Text(row.1).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                }
                .padding(.vertical, 13)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .driveSurface()
    }
}
