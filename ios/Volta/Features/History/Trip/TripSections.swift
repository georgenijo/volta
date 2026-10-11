import SwiftUI

// MARK: - Trip chrome

extension View {
    /// Small uppercase tracked label (10.5 pt), tertiary by default.
    func tripLabel(_ color: Color = HistoryTheme.tertiary, size: CGFloat = 10.5) -> some View {
        self.font(.system(size: size, weight: .medium)).tracking(size * 0.2).textCase(.uppercase).foregroundStyle(color)
            .lineLimit(1)
    }

    /// Kept for older call sites: the same uppercase caption voice.
    func tripCaption(_ color: Color = HistoryTheme.tertiary, size: CGFloat = 10) -> some View {
        tripLabel(color, size: size)
    }
}

/// A flat section of the trip screen: a hairline, an SF Symbol and an
/// uppercase tracked title with the key value on the right, then the content.
struct TripSection<Trailing: View, Content: View>: View {
    var icon: String
    var title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
            HStack(alignment: .center, spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 34, alignment: .leading)
                Text(title)
                    .font(.system(size: 15, weight: .semibold)).tracking(2.6).textCase(.uppercase)
                    .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 10)
                trailing
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 24)
            content
                .padding(.top, 22)
        }
        .padding(.bottom, 44)
    }
}

extension TripSection where Trailing == EmptyView {
    init(icon: String, title: String, @ViewBuilder content: () -> Content) {
        self.init(icon: icon, title: title, trailing: { EmptyView() }, content: content)
    }
}

/// Top-right value of a section header, in the series colour.
struct TripHeaderValue: View {
    var text: String
    var color: Color = .white
    var body: some View {
        Text(text).font(.system(size: 16, weight: .medium)).monospacedDigit().foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.75)
    }
}

/// Small solid dot used beside itinerary endpoints.
struct TripGlowDot: View {
    var color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

// MARK: - Hero

/// Distance on the left, efficiency with its gradient slider on the right,
/// the start → end itinerary with battery, then the date and times.
struct TripHero: View {
    var summary: DriveSummary
    var units: UnitPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(VoltaFormat.number(units.distanceValue(km: summary.distanceKm)))
                        .font(.system(size: 60, weight: .bold)).tracking(-1)
                        .foregroundStyle(.white).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    Text(units.distanceUnit).font(.system(size: 22, weight: .regular)).foregroundStyle(HistoryTheme.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("screen.drive-detail")
                Spacer(minLength: 8)
                efficiency.padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 12) {
                stop(summary.startCity ?? summary.startAddress, level: summary.startBatteryLevel, color: HistoryTheme.green)
                stop(summary.endCity ?? summary.endAddress, level: summary.endBatteryLevel, color: HistoryTheme.red)
            }
            .padding(.top, 30)
            Text(TripHero.dateLine(summary))
                .tripLabel(HistoryTheme.tertiary, size: 10)
                .minimumScaleFactor(0.8)
                .padding(.top, 26)
        }
    }

    private var efficiency: some View {
        let wh = summary.displayEfficiencyWhPerKm
        return VStack(alignment: .trailing, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(wh.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) } ?? "—")
                    .font(.system(size: 30, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                Text(units.efficiencyUnit).font(.system(size: 13, weight: .regular)).foregroundStyle(HistoryTheme.secondary)
            }
            TripEfficiencySlider(whPerKm: wh).frame(width: 118)
        }
        .accessibilityElement(children: .combine)
    }

    private func stop(_ address: String?, level: Int?, color: Color) -> some View {
        let place = TripPlace(address)
        return HStack(alignment: .center, spacing: 0) {
            TripGlowDot(color: color, size: 8).frame(width: 21, alignment: .leading)
            Text(place.primary)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(address == nil ? HistoryTheme.secondary : .white)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if let level {
                    Image(systemName: TripPlace.batterySymbol(level)).font(.system(size: 15, weight: .regular))
                        .foregroundStyle(HistoryTheme.secondary)
                    Text("\(level)%").font(.system(size: 21, weight: .medium)).monospacedDigit().foregroundStyle(.white)
                } else {
                    Text("—").font(.system(size: 21, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "SATURDAY, OCTOBER 10 · 19:43 — 20:15" (uppercased by the label style).
    static func dateLine(_ summary: DriveSummary, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let day = summary.start.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.wide).month(.wide).day())
        let from = VoltaFormat.clock(summary.start, timeZone: timeZone)
        let to = summary.end.map { VoltaFormat.clock($0, timeZone: timeZone) }
        return "\(day) · \(from)" + (to.map { " — \($0)" } ?? "")
    }
}

/// Efficiency on a fixed green → blue → violet → red band, so a position means
/// the same thing on every trip.
struct TripEfficiencySlider: View {
    var whPerKm: Double?
    static let colors: [Color] = [HistoryTheme.green, HistoryTheme.blue, HistoryTheme.purple, HistoryTheme.red]

    static func fraction(_ whPerKm: Double) -> Double {
        let band = TripPalette.efficiencyBand
        return min(1, max(0, (whPerKm - band.lowerBound) / (band.upperBound - band.lowerBound)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: Self.colors, startPoint: .leading, endPoint: .trailing)).opacity(0.45)
                    .frame(height: 3)
                if let whPerKm {
                    let f = Self.fraction(whPerKm)
                    let color = TripPalette.color(f, stops: [.init(r: 0.37, g: 0.80, b: 0.58), .init(r: 0.23, g: 0.51, b: 0.96),
                                                              .init(r: 0.65, g: 0.55, b: 0.98), .init(r: 0.94, g: 0.27, b: 0.27)])
                    Circle().fill(color).frame(width: 10, height: 10)
                        .shadow(color: color.opacity(0.8), radius: 5)
                        .offset(x: f * (geo.size.width - 10))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
        .accessibilityHidden(true)
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

/// Duration, energy (with regen) and average speed (with max), in three columns.
struct TripStatsRow: View {
    var summary: DriveSummary
    var units: UnitPreferences
    var regen: TripEstimate?
    var maxSpeed: TripMetric?

    var body: some View {
        let speedUnit = units.distance == .miles ? "mph" : "km/h"
        let regenKwh = TripStatsRow.regenKwh(server: summary.regenKwh, estimate: regen)
        HStack(alignment: .top, spacing: 0) {
            column("clock", "Duration", VoltaFormat.duration(TripStatsRow.durationMinutes(summary)), color: .white) { EmptyView() }
            divider
            column("bolt.fill", "Energy", summary.energyUsedKwh.map { "\(VoltaFormat.number($0)) kWh" } ?? "—",
                   color: summary.energyUsedKwh == nil ? HistoryTheme.secondary : HistoryTheme.green) {
                // No regen (the car doesn't stream pack power): no sub-line, never "0" or "—".
                if let regenKwh {
                    HStack(spacing: 7) {
                        Text(VoltaFormat.number(regenKwh))
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(HistoryTheme.green)
                        Text("Regen").tripLabel(size: 10)
                    }
                }
            }
            divider
            column("gauge.with.dots.needle.33percent", "Avg speed",
                   TripStatsRow.avgSpeedKph(summary).map { "\(VoltaFormat.number(units.distanceValue(km: $0), digits: 0)) \(speedUnit)" } ?? "—",
                   color: .white) {
                HStack(spacing: 7) {
                    Text("Max").tripLabel(size: 10)
                    Text(maxText).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                }
            }
        }
    }

    private var divider: some View { Rectangle().fill(HistoryTheme.hairline).frame(width: 1, height: 30).padding(.top, 20) }

    private func column<Sub: View>(_ icon: String, _ label: String, _ value: String, color: Color,
                                   @ViewBuilder sub: () -> Sub) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(icon == "bolt.fill" ? HistoryTheme.green : HistoryTheme.secondary)
                Text(label).tripLabel(HistoryTheme.secondary, size: 10)
            }
            Text(value)
                .font(.system(size: 22, weight: .medium)).monospacedDigit()
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
                .padding(.top, 14)
            sub().padding(.top, 14).frame(minHeight: 14)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Start to end when the drive has ended, else the reported duration.
    static func durationMinutes(_ summary: DriveSummary) -> Double {
        guard let end = summary.end, end > summary.start else { return summary.durationMin }
        return end.timeIntervalSince(summary.start) / 60
    }

    /// Odometer distance over the whole start-to-end duration (stops included).
    static func avgSpeedKph(_ summary: DriveSummary) -> Double? {
        let hours = durationMinutes(summary) / 60
        guard hours > 0, summary.distanceKm.isFinite, summary.distanceKm >= 0 else { return nil }
        return summary.distanceKm / hours
    }

    /// The server's regen when sent; otherwise the on-device estimate only when
    /// it covers the whole trip. A partial estimate would understate it, so it
    /// is not shown as a number.
    static func regenKwh(server: Double?, estimate: TripEstimate?) -> Double? {
        if let server, server.isFinite, server >= 0 { return server }
        if case .estimate(let v, _) = estimate, estimate?.isComplete == true { return v }
        return nil
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
        case .unavailable, nil: summary.maxSpeedKph.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—"
        }
    }
}

// MARK: - Sampling disclosure

/// Plain-language account of what was recorded. Shown only when the trip is
/// not densely sampled.
struct TripSamplingNote: View {
    var timeline: TripTimeline

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: timeline.quality == .partial ? "waveform.path.ecg" : "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HistoryTheme.amber)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 28)
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
            parts.append("Map gaps are preserved (longest \(VoltaFormat.duration(t.longestGap / 60))): dashed map lines only join samples and are not the driven path. Chart values are held between observations.")
        }
        if t.quality != .dense { parts.append("Regen and smoothness need denser samples.") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Cost

/// Trip cost: electric against the fuel equivalent, drawn to scale, with the
/// savings bracket. Always an estimate when energy is known (see `TripCostEstimate`).
struct TripCostCard: View {
    var estimate: TripCostEstimate?
    var editable: Bool
    var onEdit: () -> Void

    var body: some View {
        TripSection(icon: "creditcard.fill", title: "Trip cost") {
            if let estimate { TripHeaderValue(text: TripCostCard.rateText(estimate), color: .white.opacity(0.8)) }
        } content: {
            if let estimate {
                bars(estimate)
            } else {
                VStack(alignment: .leading) {
                    Text(TripCostCard.unknownReason(energyKwh: nil, rate: nil, lookup: nil))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                        .accessibilityIdentifier("trip.cost.reason")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("trip.cost")
            }
        }
    }

    private static let labelWidth: CGFloat = 80
    private static let valueWidth: CGFloat = 70

    private func bars(_ e: TripCostEstimate) -> some View {
        let top = max(e.electric, e.fuel ?? 0, 0.000_001)
        return VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                let barMax = max(10, geo.size.width - Self.labelWidth - Self.valueWidth)
                let electricWidth = max(4, barMax * e.electric / top)
                let fuelWidth = e.fuel.map { max(4, barMax * $0 / top) }
                VStack(alignment: .leading, spacing: 0) {
                    row("Electric", width: electricWidth,
                        fill: AnyShapeStyle(LinearGradient(colors: [HistoryTheme.green, HistoryTheme.green.opacity(0.75)],
                                                           startPoint: .leading, endPoint: .trailing)),
                        value: VoltaFormat.money(e.electric, currency: e.currency), valueColor: HistoryTheme.green)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("trip.cost")
                    if let fuel = e.fuel, let fuelWidth {
                        row("Fuel eq.", width: fuelWidth, fill: AnyShapeStyle(Color(hex: 0x6B5A2E)),
                            value: VoltaFormat.money(fuel, currency: e.currency), valueColor: .white.opacity(0.75))
                            .padding(.top, 16)
                        if let savings = e.savings, savings > 0 {
                            let from = Self.labelWidth + electricWidth, to = Self.labelWidth + fuelWidth
                            TripSavingsBracket()
                                .stroke(HistoryTheme.green.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                                .frame(width: max(8, to - from), height: 7)
                                .offset(x: from)
                                .padding(.top, 14)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("Savings").tripLabel(HistoryTheme.green, size: 10)
                                Text(VoltaFormat.money(savings, currency: e.currency))
                                    .font(.system(size: 18, weight: .semibold)).monospacedDigit().foregroundStyle(HistoryTheme.green)
                            }
                            .fixedSize()
                            .frame(width: max(8, to - from))
                            .offset(x: from)
                            .padding(.top, 10)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .frame(height: TripCostCard.barsHeight(e))
            HStack(alignment: .firstTextBaseline) {
                if let percent = e.percentVsFuel {
                    Text(TripCostCard.percentText(percent)).tripLabel(size: 10)
                }
                Spacer(minLength: 8)
                Text(e.source.label).tripLabel(size: 10)
            }
            .padding(.top, 26)
            if editable, e.source == .estimated {
                Button("Set your rate", action: onEdit)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(HistoryTheme.blue)
                    .padding(.top, 12)
                    .accessibilityIdentifier("trip.rate.edit")
            }
        }
    }

    private static func barsHeight(_ e: TripCostEstimate) -> CGFloat {
        guard e.fuel != nil else { return 24 }
        return (e.savings ?? 0) > 0 ? 24 + 16 + 24 + 14 + 7 + 10 + 24 : 24 + 16 + 24
    }

    private func row(_ label: String, width: CGFloat, fill: AnyShapeStyle, value: String, valueColor: Color) -> some View {
        HStack(spacing: 0) {
            Text(label).tripLabel(HistoryTheme.secondary, size: 10).frame(width: Self.labelWidth, alignment: .leading)
            RoundedRectangle(cornerRadius: 3).fill(fill).frame(width: width, height: 10)
            Text(value).font(.system(size: 17, weight: .medium)).monospacedDigit().foregroundStyle(valueColor)
                .lineLimit(1).fixedSize()
                .padding(.leading, 8)
        }
        .frame(height: 24)
    }

    /// "−69% VS FUEL" (cheaper) or "+12% VS FUEL" (dearer).
    static func percentText(_ percent: Double) -> String {
        let rounded = Int(percent.rounded())
        return (rounded < 0 ? "−\(-rounded)" : "+\(rounded)") + "% vs fuel"
    }

    static func rateText(_ estimate: TripCostEstimate) -> String {
        estimate.ratePerKwh.formatted(.currency(code: estimate.currency).precision(.fractionLength(3))) + "/kWh"
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
}

/// A shallow U under the gap between the electric and fuel bars.
struct TripSavingsBracket: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(4, rect.height)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
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
        [("Acceleration", acceleration), ("Speed", speed), ("Efficiency", efficiency), ("Smoothness", smoothness)]
    }
}

enum TripScoreStyle {
    /// Component and ring colour by value.
    static func tint(_ value: Int?) -> Color {
        guard let value else { return HistoryTheme.secondary }
        switch value {
        case 85...: return Color(hex: 0x6FD3AE)
        case 70..<85: return Color(hex: 0x5BA9C9)
        case 55..<70: return HistoryTheme.amber
        default: return Color(hex: 0xE5695F)
        }
    }

    /// One word for the overall score, shown top right.
    static func word(_ score: Int?) -> String? {
        guard let score else { return nil }
        switch score {
        case 85...: return "Calm"
        case 70..<85: return "Steady"
        case 55..<70: return "Lively"
        default: return "Aggressive"
        }
    }
}

/// Open 280° gauge with the score in the middle.
struct TripScoreRing: View {
    var score: Int?
    var size: CGFloat = 124
    private static let sweep = 280.0 / 360

    var body: some View {
        let value = score.flatMap { (0...100).contains($0) ? $0 : nil }
        ZStack {
            Circle().trim(from: 0, to: Self.sweep)
                .stroke(.white.opacity(0.12), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(90 + (360 - 280) / 2))
            if let value {
                Circle().trim(from: 0, to: Self.sweep * Double(value) / 100)
                    .stroke(TripScoreStyle.tint(value), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(90 + (360 - 280) / 2))
            }
            Text(value.map(String.init) ?? "—")
                .font(.system(size: 46, weight: .bold)).monospacedDigit().foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "Drive score \($0) of 100" } ?? "Drive score unavailable")
    }
}

/// One component: uppercase name and value over a thin bar coloured by value.
struct ScoreBreakdownRow: View {
    var title: String
    var value: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).tripLabel(HistoryTheme.secondary, size: 10)
                Spacer(minLength: 6)
                Text(value.map(String.init) ?? "—")
                    .font(.system(size: 15, weight: .medium)).monospacedDigit()
                    .foregroundStyle(value == nil ? HistoryTheme.tertiary : .white)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    if let value, value > 0 {
                        Capsule().fill(TripScoreStyle.tint(value))
                            .frame(width: max(3, geo.size.width * Double(value) / 100))
                    }
                }
            }
            .frame(height: 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value.map { "\($0) of 100" } ?? "not reported")")
    }
}

/// Driving score: ring, four component bars, hard events and peak g. The
/// score itself is unchanged; this is presentation only.
struct TripScoreCard: View {
    var score: Int?
    var breakdown: DriveScoreBreakdown
    /// Volta v1 smoothness; nil while the drive loads.
    var result: SmoothnessScore.Result?
    @State private var showsFormula = false

    var body: some View {
        TripSection(icon: "star.fill", title: "Driving score") {
            if let word = TripScoreStyle.word(score) {
                Text(word.uppercased()).font(.system(size: 16, weight: .semibold)).foregroundStyle(TripScoreStyle.tint(score))
            }
        } content: {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 26) {
                    TripScoreRing(score: score)
                    VStack(spacing: 20) {
                        ForEach(breakdown.components, id: \.title) { ScoreBreakdownRow(title: $0.title, value: $0.value) }
                    }
                }
                events
            }
        }
    }

    private var events: some View {
        HStack(spacing: 22) {
            switch result {
            case .score(let s):
                event("exclamationmark.triangle.fill", "\(s.hardEvents)", "Hard")
                event("gauge.with.dots.needle.33percent", "\(VoltaFormat.number(s.maxG, digits: 2))g", "Max")
            case .unavailable, nil:
                event("exclamationmark.triangle.fill", "—", "Hard")
                event("gauge.with.dots.needle.33percent", "—", "Max")
            }
            Spacer(minLength: 0)
            Button { showsFormula = true } label: {
                Image(systemName: "info.circle").font(.system(size: 15, weight: .regular)).foregroundStyle(HistoryTheme.tertiary)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("How smoothness is calculated")
            .popover(isPresented: $showsFormula) {
                Text(TripScoreCard.formula(result))
                    .font(.system(size: 13, weight: .regular)).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(18)
                    .frame(width: 320)
                    .presentationCompactAdaptation(.popover)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trip.score")
    }

    private func event(_ icon: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
            Text(label).tripLabel(size: 10)
        }
        .accessibilityElement(children: .combine)
    }

    static func formula(_ result: SmoothnessScore.Result?) -> String {
        if case .unavailable(let reason) = result { return "Smoothness unavailable: \(reason)\n\n" + formula }
        return formula
    }

    static let formula = """
    Volta's own measure, not comparable to scores in other apps. From recorded speed (and power when present), \
    over intervals of at most 6 s while moving above 5 km/h. Acceleration: share of accelerating time at ≤ 2.0 m/s². \
    Braking: share of braking time at ≤ 2.5 m/s². Power: share of time with power changing ≤ 15 kW/s. \
    Score is the mean of the available parts. Hard events are runs at ≥ 0.3 g. Needs ≥ 70% of the trip sampled \
    and ≥ 120 intervals. Speed limits and road type are not known, so they are not scored.
    """
}

// MARK: - Details

/// Key/value rows: uppercase tracked key, value on the right, hairlines between.
struct TripDetailsList: View {
    var rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Rectangle().fill(HistoryTheme.hairline).frame(height: 1) }
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0).tripLabel(HistoryTheme.secondary, size: 10.5)
                    Spacer(minLength: 12)
                    Text(row.1).font(.system(size: 16, weight: .regular)).foregroundStyle(.white)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                }
                .padding(.vertical, 12)
                .frame(minHeight: 39)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
