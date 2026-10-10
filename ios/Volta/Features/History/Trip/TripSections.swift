import SwiftUI

// MARK: - Hero

/// Distance + efficiency, start/end places with battery, date and times.
struct TripHero: View {
    var summary: DriveSummary
    var units: UnitPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                BigNumber(VoltaFormat.number(units.distanceValue(km: summary.distanceKm)), unit: units.distanceUnit, size: 52)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("screen.drive-detail")
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    DriveScoreRing(score: summary.efficiencyScore, size: 72)
                    if let eff = summary.efficiencyWhPerKm {
                        BigNumber(VoltaFormat.number(units.efficiencyValue(whPerKm: eff), digits: 0), unit: units.efficiencyUnit, size: 20)
                        GradientGauge(value: TripHero.efficiencyFraction(eff), colors: TripHero.efficiencyColors, knob: .ring, height: 4)
                            .frame(width: 128)
                    } else {
                        BigNumber("—", unit: units.efficiencyUnit, size: 26, color: HistoryTheme.secondary)
                        Text("Energy not recorded").font(.system(size: 11)).foregroundStyle(HistoryTheme.tertiary)
                    }
                }
                .padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 12) {
                endpoint(summary.startCity ?? summary.startAddress, level: summary.startBatteryLevel, color: HistoryTheme.green)
                endpoint(summary.endCity ?? summary.endAddress, level: summary.endBatteryLevel, color: HistoryTheme.red)
            }
            Text(dateLine)
                .voltaLabelStyle()
                .tracking(1.2)
                .accessibilityLabel(dateLine.lowercased())
        }
    }

    /// Fixed reference band so the knob means the same on every trip.
    static func efficiencyFraction(_ whPerKm: Double) -> Double {
        let band = TripPalette.efficiencyBand
        return (whPerKm - band.lowerBound) / (band.upperBound - band.lowerBound)
    }

    static let efficiencyColors: [Color] = [HistoryTheme.green, HistoryTheme.green, HistoryTheme.amber, HistoryTheme.red]

    private var dateLine: String {
        let day = summary.start.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased()
        let end = summary.end.map { " — " + $0.formatted(.dateTime.hour().minute()) } ?? ""
        return "\(day) · \(summary.start.formatted(.dateTime.hour().minute()))\(end)"
    }

    private func endpoint(_ address: String?, level: Int?, color: Color) -> some View {
        let place = TripPlace(address)
        return HStack(spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(place.primary)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(address == nil ? HistoryTheme.secondary : .white)
                .lineLimit(1)
            if let secondary = place.secondary {
                Text(secondary)
                    .font(.system(size: 13))
                    .foregroundStyle(HistoryTheme.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            if let level {
                HStack(spacing: 6) {
                    Text("\(level)%")
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                    Image(systemName: TripPlace.batterySymbol(level))
                        .font(.system(size: 15))
                        .foregroundStyle(HistoryTheme.secondary)
                }
                .foregroundStyle(.white)
            } else {
                Text("—").foregroundStyle(HistoryTheme.secondary)
            }
        }
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
        HStack(alignment: .top, spacing: 0) {
            column("DURATION", value: VoltaFormat.duration(summary.durationMin), unit: nil, sub: nil)
            divider
            column("ENERGY", value: summary.energyUsedKwh.map { VoltaFormat.number($0) } ?? "—", unit: "kWh",
                   sub: "REGEN " + Self.regenText(regen), valueColor: summary.energyUsedKwh == nil ? HistoryTheme.secondary : HistoryTheme.green)
            divider
            column("AVG SPEED", value: summary.avgSpeedKph.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—",
                   unit: speedUnit, sub: "MAX " + maxText)
        }
        .fixedSize(horizontal: false, vertical: true)
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

    private var divider: some View {
        Rectangle().fill(HistoryTheme.hairline).frame(width: 1).padding(.horizontal, 12)
    }

    private func column(_ label: String, value: String, unit: String?, sub: String?, valueColor: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).voltaLabelStyle().tracking(1.1).lineLimit(1).minimumScaleFactor(0.8)
            HistoryValue(value: value, unit: unit, size: 22, color: valueColor)
            if let sub {
                Text(sub).voltaLabelStyle().tracking(0.8).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sampling disclosure

/// Plain-language account of what was recorded. Shown above the charts
/// whenever the trip is not densely sampled.
struct TripSamplingNote: View {
    var timeline: TripTimeline

    var body: some View {
        HistoryCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: timeline.quality == .partial ? "waveform.path.ecg" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(HistoryTheme.amber)
                VStack(alignment: .leading, spacing: 6) {
                    Text(TripSamplingNote.title(timeline))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(TripSamplingNote.detail(timeline))
                        .font(.system(size: 13))
                        .foregroundStyle(HistoryTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
    var onEdit: () -> Void

    var body: some View {
        HistoryCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HistorySectionLabel(title: "Trip cost", systemImage: "dollarsign.circle")
                    Spacer()
                    if let rate {
                        Text("\(TripCostCard.rateText(rate))/kWh")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(HistoryTheme.secondary)
                            .monospacedDigit()
                    }
                }
                if let rate, let cost = rate.cost(energyKwh: energyKwh) {
                    HistoryValue(value: VoltaFormat.money(cost, currency: rate.currency), unit: nil, size: 30)
                        .accessibilityIdentifier("trip.cost")
                    Text(sourceText(rate)).font(.system(size: 12)).foregroundStyle(HistoryTheme.tertiary)
                } else {
                    Text("Cost unknown")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(HistoryTheme.secondary)
                        .accessibilityIdentifier("trip.cost")
                    Text(TripCostCard.unknownReason(energyKwh: energyKwh, rate: rate, lookup: lookup))
                        .font(.system(size: 12)).foregroundStyle(HistoryTheme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("trip.cost.reason")
                }
                if editable {
                    Button(rate?.source == .manual ? "Edit rate" : "Set your rate", action: onEdit)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HistoryTheme.blue)
                        .accessibilityIdentifier("trip.rate.edit")
                }
            }
        }
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

// MARK: - Smoothness

struct TripScoreCard: View {
    var result: SmoothnessScore.Result
    @State private var showsFormula = false

    var body: some View {
        HistoryCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    HistorySectionLabel(title: "Smoothness", systemImage: "gauge.with.needle")
                    Spacer()
                    Text("VOLTA V1").voltaLabelStyle().tracking(1)
                }
                switch result {
                case .score(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        BigNumber("\(s.score)", size: 44)
                        Text(s.label.uppercased())
                            .font(.system(size: 13, weight: .bold)).tracking(1.4)
                            .foregroundStyle(HistoryTheme.green)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(s.hardEvents) HARD").voltaLabelStyle()
                            Text("\(VoltaFormat.number(s.maxG, digits: 2))g MAX").voltaLabelStyle()
                        }
                    }
                    .accessibilityIdentifier("trip.score")
                    ForEach(s.parts) { part in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(part.name).font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                                Spacer()
                                Text("\(Int(part.score.rounded()))").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(HistoryTheme.track)
                                    Capsule().fill(HistoryTheme.green).frame(width: geo.size.width * part.score / 100)
                                }
                            }
                            .frame(height: 5)
                        }
                    }
                case .unavailable(let reason):
                    Text("Unavailable")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(HistoryTheme.secondary)
                        .accessibilityIdentifier("trip.score")
                    Text(reason).font(.system(size: 12)).foregroundStyle(HistoryTheme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup(isExpanded: $showsFormula) {
                    Text(TripScoreCard.formula)
                        .font(.system(size: 12))
                        .foregroundStyle(HistoryTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                } label: {
                    Text("How it's calculated").font(.system(size: 13, weight: .semibold)).foregroundStyle(HistoryTheme.blue)
                }
                .tint(HistoryTheme.blue)
            }
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
        HistoryCard {
            VStack(alignment: .leading, spacing: 12) {
                HistorySectionLabel(title: "Not recorded yet", systemImage: "tray")
                row("Temperatures", "Cabin and outside traces need per-sample temperatures." + (outsideAvg.map { " Trip outside average: \($0)." } ?? ""))
                row("Energy remaining", "Needs per-sample energy remaining or usable battery level.")
                row("Range efficiency", "Needs rated range at the start and end of the trip.")
            }
        }
        .accessibilityIdentifier("trip.unrecorded")
    }

    private func row(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            Text(text).font(.system(size: 12)).foregroundStyle(HistoryTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Details

struct TripDetailsList: View {
    var rows: [(String, String)]

    var body: some View {
        HistoryCard(padding: 0) {
            VStack(spacing: 0) {
                HistorySectionLabel(title: "Details", systemImage: "list.bullet")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 14)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HairlineDivider()
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0).font(.system(size: 14)).foregroundStyle(HistoryTheme.secondary)
                        Spacer(minLength: 12)
                        Text(row.1).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
        }
    }
}
