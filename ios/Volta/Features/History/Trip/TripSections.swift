import SwiftUI

// MARK: - Trip chrome

extension View {
    /// Small label in sentence case, as written: 12 pt at least, following
    /// Dynamic Type, tertiary by default. `size` is the design size; smaller
    /// asks get 12. (No tracked capitals; see DesignSystem/README.md.)
    func tripLabel(_ color: Color = HistoryTheme.tertiary, size: CGFloat = 12) -> some View {
        self.scaledFont(max(12, size), weight: .medium).foregroundStyle(color)
            .lineLimit(1)
    }

    /// Kept for older call sites: the same caption voice.
    func tripCaption(_ color: Color = HistoryTheme.tertiary, size: CGFloat = 8) -> some View {
        tripLabel(color, size: size)
    }
}

/// A flat section of the trip screen: a hairline, an SF Symbol and a
/// sentence-case title with the key value on the right, then the content.
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.voltaInk.opacity(0.75))
                    .frame(width: 34, alignment: .leading)
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(.voltaTextPrimary).lineLimit(1).minimumScaleFactor(0.8)
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
    var color: Color = .voltaTextPrimary
    var body: some View {
        Text(text).font(.system(.footnote, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.75)
            .voltaRolling(text)
    }
}

// MARK: - Hero

/// Distance on the left, efficiency with its labelled bar on the right, the
/// start → end itinerary with battery, then the date and times.
struct TripHero: View {
    var summary: DriveSummary
    var units: UnitPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    RollingNumber(value: units.distanceValue(km: summary.distanceKm)) { VoltaFormat.number($0) }
                        .font(.system(size: 60, weight: .bold)).tracking(-1)
                        .foregroundStyle(.voltaTextPrimary).lineLimit(1).minimumScaleFactor(0.5)
                    Text(units.distanceUnit).font(.system(size: 22, weight: .regular)).foregroundStyle(HistoryTheme.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("screen.drive-detail")
                Spacer(minLength: 8)
                efficiency.padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 12) {
                stop(summary.startCity ?? summary.startAddress, level: summary.startBatteryLevel, marker: .start)
                stop(summary.endCity ?? summary.endAddress, level: summary.endBatteryLevel, marker: .end)
            }
            .padding(.top, 30)
            Text(TripHero.dateLine(summary))
                .tripLabel(HistoryTheme.secondary, size: 13)
                .minimumScaleFactor(0.8)
                .padding(.top, 26)
        }
    }

    private var efficiency: some View {
        let wh = summary.displayEfficiencyWhPerKm
        return VStack(alignment: .trailing, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                HistoryRollingFigure(value: wh.map { units.efficiencyValue(whPerKm: $0) }) { VoltaFormat.number($0, digits: 0) }
                    .font(.system(size: 30, weight: .bold)).foregroundStyle(.voltaTextPrimary)
                Text(units.efficiencyUnit).font(.system(size: 13, weight: .regular)).foregroundStyle(HistoryTheme.secondary)
            }
            TripEfficiencySlider(whPerKm: wh, reference: EfficiencyReference(ratedWhPerKm: summary.ratedWhPerKm)).frame(width: 140)
        }
        .accessibilityElement(children: .combine)
    }

    private func stop(_ address: String?, level: Int?, marker: RouteEndpoint) -> some View {
        let place = TripPlace(address)
        return HStack(alignment: .center, spacing: 0) {
            RouteEndpointMarker(kind: marker, size: 10).frame(width: 21, alignment: .leading)
            Text(place.primary)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(address == nil ? HistoryTheme.secondary : Color.voltaTextPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if let level {
                    Image(systemName: TripPlace.batterySymbol(level)).font(.system(size: 15, weight: .regular))
                        .foregroundStyle(HistoryTheme.secondary)
                    Text("\(level)%").font(.system(size: 20, weight: .medium)).monospacedDigit().foregroundStyle(.voltaTextPrimary)
                } else {
                    Text("—").font(.system(size: 20, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Saturday, October 10 · 19:43 — 20:15".
    static func dateLine(_ summary: DriveSummary, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let day = summary.start.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.wide).month(.wide).day())
        let from = VoltaFormat.clock(summary.start, timeZone: timeZone)
        let to = summary.end.map { VoltaFormat.clock($0, timeZone: timeZone) }
        return "\(day) · \(from)" + (to.map { " — \($0)" } ?? "")
    }
}

/// Efficiency as a level against the car's own rating: the bar fills from
/// the efficient end (half the rated consumption) towards the heavy end
/// (1.75 times it), with a tick at the rating, both ends labelled. Green while
/// the drive is at or near its rating, amber when it was clearly heavier.
/// Regen (negative consumption) pins to the efficient end. Not a slider: it
/// has no thumb, because nothing here can be dragged.
struct TripEfficiencySlider: View {
    var whPerKm: Double?
    var reference = EfficiencyReference(ratedWhPerKm: nil)
    @Environment(\.units) private var units
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    /// Above this share of the rating, the fill turns amber ("heavy").
    static let heavyRatio = 1.2

    /// Position along the bar, 0...1.
    static func fraction(_ whPerKm: Double, reference: EfficiencyReference) -> Double {
        let domain = RoutePalette.efficiency.domain
        return min(1, max(0, (whPerKm / reference.whPerKm - domain.lowerBound) / (domain.upperBound - domain.lowerBound)))
    }

    /// Green at or near the rating, amber when heavier.
    static func color(_ whPerKm: Double, reference: EfficiencyReference) -> Color {
        whPerKm / reference.whPerKm > heavyRatio ? HistoryTheme.amber : HistoryTheme.green
    }

    var body: some View {
        let domain = RoutePalette.efficiency.domain
        let tick = (1 - domain.lowerBound) / (domain.upperBound - domain.lowerBound)
        let shown = settled || reduceMotion
        VStack(alignment: .trailing, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.voltaTrack).frame(height: 6)
                    if let whPerKm {
                        Capsule().fill(Self.color(whPerKm, reference: reference))
                            .frame(width: max(6, geo.size.width * Self.fraction(whPerKm, reference: reference) * (shown ? 1 : 0)), height: 6)
                    }
                    Capsule().fill(Color.voltaTextPrimary).frame(width: 2, height: 12)
                        .offset(x: geo.size.width * tick - 1)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 12)
            HStack(spacing: 4) {
                Text("Efficient")
                Spacer(minLength: 4)
                Text("Heavy")
            }
            .font(.caption2)
            .foregroundStyle(HistoryTheme.tertiary)
            .lineLimit(1)
            // The tick is the car's rating, or an estimate when it isn't recorded: say which.
            if whPerKm != nil {
                Text(reference.isRated ? "Tick: rated \(referenceValue)" : RouteLegendModel.referenceLabel(reference, units: units))
                    .scaledFont(11, weight: .medium)
                    .foregroundStyle(HistoryTheme.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .animation(VoltaMotion.animation(VoltaMotion.settle, reduceMotion: reduceMotion), value: whPerKm)
        .onAppear {
            guard !settled else { return }
            withAnimation(VoltaMotion.animation(VoltaMotion.settle.delay(0.15), reduceMotion: reduceMotion)) { settled = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHidden(whPerKm == nil)
    }

    private var referenceValue: String {
        VoltaFormat.number(units.efficiencyValue(whPerKm: reference.whPerKm), digits: 0)
    }

    private var accessibilityText: String {
        let value = referenceValue
        let heavy = whPerKm.map { $0 / reference.whPerKm > Self.heavyRatio } == true ? "Heavier than usual. " : ""
        return heavy + (reference.isRated
            ? "Compared with the car's rated \(value) \(units.efficiencyUnit)"
            : "Compared with an estimated \(value) \(units.efficiencyUnit), because the car's rating isn't recorded")
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
            column("clock", "Duration", VoltaFormat.duration(TripStatsRow.durationMinutes(summary)), color: Color.voltaTextPrimary) { EmptyView() }
            divider
            column("bolt.fill", "Energy used", summary.energyUsedKwh.map { "\(VoltaFormat.number($0)) kWh" } ?? "—",
                   color: summary.energyUsedKwh == nil ? HistoryTheme.secondary : Color.voltaTextPrimary) {
                // No regen (the car doesn't stream pack power): no sub-line, never "0" or "—".
                if let regenKwh {
                    HStack(spacing: 7) {
                        Text(VoltaFormat.number(regenKwh))
                            .scaledFont(12, weight: .semibold).monospacedDigit().foregroundStyle(HistoryTheme.green)
                        Text("regenerated").tripLabel()
                    }
                }
            }
            divider
            column("gauge.with.dots.needle.33percent", "Average speed",
                   TripStatsRow.avgSpeedKph(summary).map { "\(VoltaFormat.number(units.distanceValue(km: $0), digits: 0)) \(speedUnit)" } ?? "—",
                   color: Color.voltaTextPrimary) {
                HStack(spacing: 7) {
                    Text("Top").tripLabel()
                    Text(maxText).scaledFont(12, weight: .semibold).monospacedDigit().foregroundStyle(Color.voltaInk.opacity(0.85))
                }
            }
        }
    }

    private var divider: some View { Rectangle().fill(HistoryTheme.hairline).frame(width: 1, height: 30).padding(.top, 20) }

    private func column<Sub: View>(_ icon: String, _ label: String, _ value: String, color: Color,
                                   @ViewBuilder sub: () -> Sub) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(HistoryTheme.secondary)
                Text(label).tripLabel(HistoryTheme.secondary)
            }
            Text(value)
                .font(.system(size: 19, weight: .medium)).monospacedDigit()
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
                .voltaRolling(value)
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

// MARK: - Cost

/// Trip cost: electric against the fuel equivalent, drawn to one scale from
/// zero, with the savings bracket. Cost is not a state, so the bars are ink
/// and grey; green stays for energy in and efficiency. Always an estimate
/// when energy is known (see `TripCostEstimate`).
struct TripCostCard: View {
    var estimate: TripCostEstimate?
    var editable: Bool
    var onEdit: () -> Void
    /// False until the card appears, so the bars grow out from zero.
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TripSection(icon: "creditcard.fill", title: "Trip cost") {
            if let estimate { TripHeaderValue(text: TripCostCard.rateText(estimate), color: Color.voltaInk.opacity(0.8)) }
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
    private static let rowHeight: CGFloat = 16
    private static let rowGap: CGFloat = 10
    /// Fuel's bar: a quiet grey behind electric's ink.
    private static let fuelFill = Color.voltaInk.opacity(0.28)

    private func bars(_ e: TripCostEstimate) -> some View {
        let top = max(e.electric, e.fuel ?? 0, 0.000_001)
        return VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                let barMax = max(10, geo.size.width - Self.labelWidth - Self.valueWidth)
                let electricWidth = max(4, barMax * e.electric / top)
                let fuelWidth = e.fuel.map { max(4, barMax * $0 / top) }
                VStack(alignment: .leading, spacing: 0) {
                    row("Electric", width: electricWidth,
                        fill: AnyShapeStyle(Color.voltaTextPrimary),
                        value: VoltaFormat.money(e.electric, currency: e.currency), valueColor: Color.voltaTextPrimary)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("trip.cost")
                    if let fuel = e.fuel, let fuelWidth {
                        row("Fuel", width: fuelWidth, fill: AnyShapeStyle(Self.fuelFill),
                            value: VoltaFormat.money(fuel, currency: e.currency), valueColor: Color.voltaTextPrimary.opacity(0.75))
                            .padding(.top, Self.rowGap)
                        if let savings = e.savings, savings > 0 {
                            let from = Self.labelWidth + electricWidth, to = Self.labelWidth + fuelWidth
                            TripSavingsBracket()
                                .stroke(HistoryTheme.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                                .frame(width: max(8, to - from), height: 7)
                                .offset(x: from)
                                .padding(.top, 14)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("Saved").tripLabel(HistoryTheme.secondary)
                                Text(VoltaFormat.money(savings, currency: e.currency))
                                    .font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Color.voltaTextPrimary)
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
            .onAppear {
                guard !grown else { return }
                withAnimation(VoltaMotion.animation(VoltaMotion.settle.delay(0.1), reduceMotion: reduceMotion)) { grown = true }
            }
            HStack(alignment: .firstTextBaseline) {
                if let percent = e.percentVsFuel {
                    Text(TripCostCard.percentText(percent)).tripLabel()
                }
                Spacer(minLength: 8)
                Text(e.source.label).tripLabel()
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
        let row = Self.rowHeight
        guard e.fuel != nil else { return row }
        return (e.savings ?? 0) > 0 ? row + rowGap + row + 14 + 7 + 10 + 20 : row + rowGap + row
    }

    private func row(_ label: String, width: CGFloat, fill: AnyShapeStyle, value: String, valueColor: Color) -> some View {
        HStack(spacing: 0) {
            Text(label).tripLabel(HistoryTheme.secondary).frame(width: Self.labelWidth, alignment: .leading)
            RoundedRectangle(cornerRadius: 3).fill(fill).frame(width: grown || reduceMotion ? width : 0, height: 10)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(valueColor)
                .lineLimit(1).fixedSize()
                .padding(.leading, 8)
        }
        .frame(height: Self.rowHeight)
    }

    /// "−69% vs fuel" (cheaper) or "+12% vs fuel" (dearer).
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
    /// Component and ring colour by value: the same bands as every score ring.
    static func tint(_ value: Int?) -> Color { DriveScoreTint.color(value) }

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

/// Open 280° gauge of the score (0–100) with the score in the middle and
/// both ends labelled; the arc settles to its value as it appears.
struct TripScoreRing: View {
    var score: Int?
    var size: CGFloat = 124
    private static let sweep = 280.0 / 360
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let value = score.flatMap { (0...100).contains($0) ? $0 : nil }
        let shown = settled || reduceMotion
        ZStack {
            Circle().trim(from: 0, to: Self.sweep)
                .stroke(Color.voltaInk.opacity(0.12), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(90 + (360 - 280) / 2))
            if let value {
                Circle().trim(from: 0, to: Self.sweep * Double(value) / 100 * (shown ? 1 : 0))
                    .stroke(TripScoreStyle.tint(value), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(90 + (360 - 280) / 2))
            }
            HistoryRollingFigure(value: value.map(Double.init)) { String(Int($0.rounded())) }
                .font(.system(size: 40, weight: .bold)).foregroundStyle(.voltaTextPrimary)
            // The gauge's ends, in its open gap at the bottom.
            HStack {
                Text("0")
                Spacer(minLength: 0)
                Text("100")
            }
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(HistoryTheme.tertiary)
            .frame(width: size * 0.62)
            .offset(y: size * 0.47)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !settled else { return }
            withAnimation(VoltaMotion.animation(VoltaMotion.settle.delay(0.1), reduceMotion: reduceMotion)) { settled = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "Drive score \($0) of 100" } ?? "Drive score unavailable")
    }
}

/// One component: its name and value over a thin 0–100 bar filled from the
/// start, coloured by band. The stack's shared ends are labelled below it.
struct ScoreBreakdownRow: View {
    var title: String
    var value: Int?
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).tripLabel(HistoryTheme.secondary)
                Spacer(minLength: 6)
                Text(value.map(String.init) ?? "—")
                    .scaledFont(12, weight: .medium).monospacedDigit()
                    .foregroundStyle(value == nil ? HistoryTheme.tertiary : Color.voltaTextPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.voltaInk.opacity(0.08))
                    if let value, value > 0 {
                        Capsule().fill(TripScoreStyle.tint(value))
                            .frame(width: max(3, geo.size.width * Double(value) / 100 * (settled || reduceMotion ? 1 : 0)))
                    }
                }
            }
            .frame(height: 3)
        }
        .onAppear {
            guard !settled else { return }
            withAnimation(VoltaMotion.animation(VoltaMotion.settle.delay(0.15), reduceMotion: reduceMotion)) { settled = true }
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
                Text(word).font(.system(.footnote, weight: .semibold)).foregroundStyle(TripScoreStyle.tint(score))
            }
        } content: {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 26) {
                    TripScoreRing(score: score)
                    VStack(spacing: 20) {
                        ForEach(breakdown.components, id: \.title) { ScoreBreakdownRow(title: $0.title, value: $0.value) }
                        HStack {
                            Text("0")
                            Spacer(minLength: 8)
                            Text("100")
                        }
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(HistoryTheme.tertiary)
                        .padding(.top, -12)
                        .accessibilityHidden(true)
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
                event("exclamationmark.triangle.fill", "\(s.hardEvents)", s.hardEvents == 1 ? "hard event" : "hard events")
                event("gauge.with.dots.needle.33percent", "\(VoltaFormat.number(s.maxG, digits: 2)) g", "peak")
            case .unavailable, nil:
                event("exclamationmark.triangle.fill", "—", "hard events")
                event("gauge.with.dots.needle.33percent", "—", "peak")
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
                    .font(.system(size: 13, weight: .regular)).foregroundStyle(Color.voltaInk.opacity(0.85))
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
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(.voltaTextPrimary)
            Text(label).tripLabel()
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

/// Key/value rows: the key in sentence case, value on the right, hairlines between.
struct TripDetailsList: View {
    var rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Rectangle().fill(HistoryTheme.hairline).frame(height: 1) }
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0).font(.subheadline).foregroundStyle(HistoryTheme.secondary).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(row.1).font(.system(size: 16, weight: .regular)).foregroundStyle(.voltaTextPrimary)
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
