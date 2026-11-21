import Accessibility
import SwiftUI

/// Neutral marks for the Parked summary. Both clear 3:1 against the card
/// (#202020) and the background (#171717), as non-text marks must.
enum ParkedPalette {
    /// Share bars and ordinary daily bars (about 5:1 on the background).
    static let bar = Color(light: 0x86868B, dark: 0x8A8A8A)
    static let track = Color.voltaInk.opacity(0.08)
}

/// The Parked summary: where the car sat, one measured finding when the
/// data supports it, loss by day, time asleep and the fastest drain. The
/// right half of the inner display opened flat, and a pushed page elsewhere.
struct ParkedOverview: View {
    var summary: ParkedSummary
    /// A pushed page's title, drawn in the content while the bars are on the side.
    var title: String? = nil
    var open: (IdleSummary) -> Void
    @Environment(\.units) private var units
    @Environment(\.barsOnSide) private var barsOnSide

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if barsOnSide, let title {
                    Text(title)
                        .font(.system(.title, weight: .bold))
                        .foregroundStyle(Color.voltaTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                places.voltaFocusIn(0)
                if let finding = summary.finding {
                    ParkedFindingCard(finding: finding).voltaFocusIn(1)
                }
                if !summary.days.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("Loss by day", trailing: "\(units.distanceUnit), by the day each stop ended")
                        ParkedLossChart(days: summary.days)
                    }
                }
                if let asleep = summary.asleep {
                    ParkedAsleepView(asleep: asleep)
                }
                if let fastest = summary.fastest {
                    Button { open(fastest) } label: {
                        ParkedFastestTile(stop: fastest, average: summary.total.perDayKm)
                    }
                    .buttonStyle(VoltaPressStyle())
                    .accessibilityIdentifier("button.parked.fastest")
                }
                if summary.partial || !summary.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if summary.partial {
                            Text("Covers the \(summary.total.stops) stops loaded so far; more load as the list scrolls.")
                        }
                        ForEach(summary.notes, id: \.self) { Text($0) }
                        Text("Rates divide recorded range loss by the time parked at stops that recorded it.")
                    }
                    .font(.caption)
                    .foregroundStyle(HistoryTheme.secondary)
                }
            }
            .padding(.horizontal, VoltaSpacing.screen)
            .padding(.top, 22)
            .voltaReadableWidth()
        }
        .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .historyScreenBackground()
        .accessibilityIdentifier("scroll.parked-summary")
    }

    private var places: some View {
        VStack(alignment: .leading, spacing: 4) {
            ParkedPlacesHeader()
                .accessibilityIdentifier("screen.parked-summary")
            ForEach(summary.shownPlaces) { place in
                ParkedPlaceRow(place: place)
            }
        }
    }

    private func sectionHeader(_ title: String, trailing: String) -> some View {
        ParkedLabelRow(title: title) {
            Text(trailing)
                .font(.caption)
                .foregroundStyle(HistoryTheme.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Places

struct ParkedPlacesHeader: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var column: CGFloat = 58

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Where it sat").voltaLabelStyle().accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if !typeSize.isAccessibilitySize {
                Text("Parked").voltaLabelStyle().frame(minWidth: column, alignment: .trailing)
                    .accessibilityHidden(true)
                Text("Lost").voltaLabelStyle().frame(minWidth: column, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
        .padding(.bottom, 4)
    }
}

/// A place: name and rate, a neutral bar for its share of parked time, then
/// time parked and range lost. The rate turns amber only by the stated rule
/// (`ParkedSummary.isNotable`).
struct ParkedPlaceRow: View {
    var place: ParkedPlace
    var compact = false
    @Environment(\.units) private var units
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @ScaledMetric(relativeTo: .subheadline) private var nameWidth: CGFloat = 112
    @ScaledMetric(relativeTo: .footnote) private var column: CGFloat = 58

    var body: some View {
        let text = ParkedText(units: units)
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    name(text)
                    ParkedShareBar(share: place.share)
                    Text("Parked \(ParkedText.span(place.tally.minutes)) · Lost \(lostText(text))")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(Color.voltaTextPrimary)
                }
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 10) {
                    name(text).frame(width: nameWidth, alignment: .leading)
                    ParkedShareBar(share: place.share)
                    Text(ParkedText.span(place.tally.minutes))
                        .frame(minWidth: column, alignment: .trailing)
                    Text(lostText(text))
                        .frame(minWidth: column, alignment: .trailing)
                }
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(Color.voltaTextPrimary)
                .frame(minHeight: 50)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(text))
    }

    private func name(_ text: ParkedText) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(place.name)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Color.voltaTextPrimary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 3) {
                if place.isNotable && withoutColor {
                    Image(systemName: "arrow.up").accessibilityHidden(true)
                }
                Text(rateText(text))
            }
            .font(.caption)
            .foregroundStyle(place.isNotable ? HistoryTheme.amber : HistoryTheme.secondary)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
        }
    }

    private func rateText(_ text: ParkedText) -> String {
        if let rate = place.tally.perDayKm { return text.rate(rate) }
        return place.tally.lost == nil ? "Loss not recorded" : "Too short for a rate"
    }

    private func lostText(_ text: ParkedText) -> String {
        place.tally.lost.map(text.distance) ?? "—"
    }

    private func spoken(_ text: ParkedText) -> String {
        var line = "\(place.name): parked \(ParkedText.spokenSpan(place.tally.minutes)), \(Int((place.share * 100).rounded())) percent of parked time"
        if let lost = place.tally.lost {
            line += ". Lost \(text.spokenDistance(lost))"
            if let rate = place.tally.perDayKm { line += ", \(text.spokenDistance(rate)) a day" }
        } else {
            line += ". Loss not recorded"
        }
        if place.isNotable { line += ", well above this car's average" }
        if place.tally.isPartial {
            line += ". Range loss recorded for \(place.tally.measuredStops) of \(place.tally.stops) stops"
        }
        return line + "."
    }
}

/// A neutral share bar on a faint track: 0 at the start, the whole at the
/// end, filled from the start. In the places table every row's bar shares that
/// one scale (each place's share of parked time) and the row speaks its
/// percentage, so the bars carry no end labels of their own; `endLabels`
/// adds "0%" and "100%" where a bar stands alone (Asleep). It settles to its
/// value as it appears.
struct ParkedShareBar: View {
    var share: Double
    var tint: Color = ParkedPalette.bar
    var endLabels = false
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(ParkedPalette.track)
                    Capsule().fill(tint)
                        .frame(width: max(share > 0 ? 6 : 0, proxy.size.width * min(1, max(0, share)) * (settled || reduceMotion ? 1 : 0)))
                }
            }
            .frame(height: 8)
            if endLabels {
                HStack {
                    Text("0%")
                    Spacer(minLength: 8)
                    Text("100%")
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(HistoryTheme.tertiary)
            }
        }
        .animation(VoltaMotion.animation(VoltaMotion.settle, reduceMotion: reduceMotion), value: share)
        .onAppear {
            guard !settled else { return }
            withAnimation(VoltaMotion.animation(VoltaMotion.settle.delay(0.1), reduceMotion: reduceMotion)) { settled = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Finding

/// One measured comparison, stated as a record of the past: no cause, no
/// advice. Its border turns amber only when the higher place is also clearly
/// above the car's own average (the same rule as its row); the fill stays
/// the card's, with no tinted wash.
struct ParkedFindingCard: View {
    var finding: ParkedFinding
    @Environment(\.units) private var units

    var body: some View {
        let words = ParkedText(units: units).finding(finding)
        let tint = finding.higher.isNotable ? HistoryTheme.amber : Color.voltaTextPrimary
        (Text(words.headline).fontWeight(.semibold).foregroundStyle(Color.voltaTextPrimary)
         + Text(" " + words.detail).foregroundStyle(HistoryTheme.secondary))
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .voltaCardBackground(radius: 16)
            .overlay {
                if finding.higher.isNotable {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(tint.opacity(0.6), lineWidth: 1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("parked.finding")
    }
}

// MARK: - Loss by day

/// Daily bars of range lost, by the day each stop ended. Today is outlined
/// (still in progress); the highest day is amber when it is clearly above
/// the period's daily mean. A labelled y-axis; VoiceOver gets an audio graph.
struct ParkedLossChart: View {
    var days: [ParkedDay]
    @Environment(\.units) private var units
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// False until the chart appears, so the bars grow from the baseline.
    @State private var grown = false
    @ScaledMetric(relativeTo: .caption2) private var axisWidth: CGFloat = 24
    @ScaledMetric(relativeTo: .caption2) private var labelHeight: CGFloat = 18

    /// Grows with the text so the axis labels keep their spacing.
    @ScaledMetric(relativeTo: .caption2) private var scaledPlot: CGFloat = 104
    private var plotHeight: CGFloat { min(260, max(104, scaledPlot)) }

    var body: some View {
        let values = days.map { $0.lostKm.map { units.distanceValue(km: $0) } }
        let top = Self.axisTop(values.compactMap { $0 }.max() ?? 0)
        let ticks = Self.ticks(top)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    ForEach(ticks, id: \.self) { tick in
                        Text(Self.tickLabel(tick))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(HistoryTheme.secondary)
                            .position(x: axisWidth / 2, y: plotHeight * (1 - tick / top))
                    }
                }
                .frame(width: axisWidth, height: plotHeight)
                GeometryReader { proxy in
                    let step = proxy.size.width / CGFloat(max(1, days.count))
                    let gap = min(3, step * 0.3)
                    ZStack(alignment: .bottomLeading) {
                        ForEach(ticks, id: \.self) { tick in
                            Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
                                .offset(y: -plotHeight * tick / top)
                        }
                        ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                            bar(day, value: values[index], top: top, width: max(1, step - gap))
                                .offset(x: CGFloat(index) * step + gap / 2)
                        }
                    }
                    .frame(width: proxy.size.width, height: plotHeight, alignment: .bottomLeading)
                }
                .frame(height: plotHeight)
            }
            axisLabels
                .padding(.leading, axisWidth + 6)
                .frame(height: labelHeight)
        }
        // Room for the top tick label, which centres on the top gridline.
        .padding(.top, labelHeight / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Range lost by day")
        .accessibilityValue(summaryText)
        .accessibilityChartDescriptor(ParkedLossChartDescriptor(days: days, units: units))
        .onAppear {
            guard !grown else { return }
            withAnimation(VoltaMotion.animation(VoltaMotion.settle.delay(0.1), reduceMotion: reduceMotion)) { grown = true }
        }
    }

    @ViewBuilder private func bar(_ day: ParkedDay, value: Double?, top: Double, width: CGFloat) -> some View {
        let height = max(value.map { $0 > 0 ? 2 : 0 } ?? 0, plotHeight * CGFloat((value ?? 0) / top)) * (grown || reduceMotion ? 1 : 0)
        if day.isToday {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(Color.voltaTextPrimary, lineWidth: 1.5)
                .frame(width: max(width, 4), height: max(height, 8))
        } else {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(day.isHighest ? HistoryTheme.amber : ParkedPalette.bar)
                .frame(width: width, height: height)
        }
    }

    /// First day, the highest day when amber, and today.
    private var axisLabels: some View {
        GeometryReader { proxy in
            let step = proxy.size.width / CGFloat(max(1, days.count))
            let highest = days.firstIndex(where: \.isHighest)
            ZStack(alignment: .topLeading) {
                if let first = days.first {
                    label(first.day, color: HistoryTheme.secondary)
                        .fixedSize()
                        .alignmentGuide(.leading) { _ in 0 }
                }
                if let highest, highest > 0, highest < days.count - 1,
                   CGFloat(highest) * step > 64, proxy.size.width - CGFloat(highest + 1) * step > 56 {
                    label(days[highest].day, color: HistoryTheme.amber)
                        .fixedSize()
                        .position(x: (CGFloat(highest) + 0.5) * step, y: 8)
                }
                if let last = days.last, days.count > 1 {
                    Group {
                        if last.isToday {
                            Text("Today").voltaLabelStyle(color: Color.voltaTextPrimary)
                        } else {
                            label(last.day, color: HistoryTheme.secondary)
                        }
                    }
                    .fixedSize()
                    .frame(width: proxy.size.width, alignment: .trailing)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func label(_ day: Date, color: Color) -> some View {
        Text(day.formatted(.dateTime.month(.abbreviated).day())).voltaLabelStyle(color: color)
    }

    private var summaryText: String {
        let text = ParkedText(units: units)
        var parts = ["\(days.count) days"]
        if let high = days.max(by: { ($0.lostKm ?? 0) < ($1.lostKm ?? 0) }), let km = high.lostKm, km > 0 {
            parts.append("most on \(high.day.formatted(.dateTime.month(.wide).day())), \(text.spokenDistance(km))")
        }
        if let today = days.last, today.isToday {
            parts.append("today so far \(today.lostKm.map(text.spokenDistance) ?? "not recorded")")
        }
        return parts.joined(separator: "; ")
    }

    /// Round ticks from the baseline: a step of 1, 2, 2.5 or 5 times a power
    /// of ten, so the top (three steps) clears the highest value. A highest
    /// day of 4.4 gives 0, 2, 4, 6.
    static func axisTop(_ value: Double) -> Double { step(value) * 3 }

    static func step(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let raw = value / 3
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? 10 * magnitude
        return step
    }

    static func ticks(_ top: Double) -> [Double] { (0...3).map { top * Double($0) / 3 } }

    /// As few decimals as the tick needs: "6", "7.5", "0.25".
    static func tickLabel(_ value: Double) -> String {
        let digits = (0...2).first { abs((value * pow(10, Double($0))).rounded() - value * pow(10, Double($0))) < 1e-6 } ?? 2
        return VoltaFormat.number(value, digits: digits)
    }
}

/// Audio graph for the loss chart.
struct ParkedLossChartDescriptor: AXChartDescriptorRepresentable {
    var days: [ParkedDay]
    var units: UnitPreferences

    func makeChartDescriptor() -> AXChartDescriptor {
        let unit = units.distance == .miles ? "miles" : "kilometers"
        let labels = days.map { $0.day.formatted(.dateTime.month(.abbreviated).day()) }
        let values = days.map { $0.lostKm.map { units.distanceValue(km: $0) } }
        let top = ParkedLossChart.axisTop(values.compactMap { $0 }.max() ?? 0)
        let x = AXCategoricalDataAxisDescriptor(title: "Day the stop ended", categoryOrder: labels)
        let y = AXNumericDataAxisDescriptor(title: "Range lost, \(unit)", range: 0...top, gridlinePositions: ParkedLossChart.ticks(top)) {
            "\(VoltaFormat.number($0)) \(unit)"
        }
        let points = zip(labels, zip(days, values)).compactMap { label, pair -> AXDataPoint? in
            guard let value = pair.1 else { return nil }
            return AXDataPoint(x: label, y: value, additionalValues: [],
                               label: pair.0.isToday ? "Today, in progress" : (pair.0.isHighest ? "Highest day" : nil))
        }
        return AXChartDescriptor(title: "Range lost while parked, by day",
                                 summary: "Each bar is the range lost by stops that ended that day. Days whose stops recorded no loss are left out.",
                                 xAxis: x, yAxis: y, additionalAxes: [],
                                 series: [AXDataSeriesDescriptor(name: "Range lost", isContinuous: false, dataPoints: points)])
    }
}

// MARK: - Asleep

/// Share of parked time asleep, over only the stops that recorded it.
struct ParkedAsleepView: View {
    var asleep: ParkedAsleep

    var body: some View {
        let percent = Int((asleep.share * 100).rounded())
        VStack(alignment: .leading, spacing: 8) {
            ParkedLabelRow(title: "Asleep") {
                Text("recorded for \(asleep.coveredStops) of \(asleep.stops) stops")
                    .font(.caption)
                    .foregroundStyle(HistoryTheme.secondary)
            }
            ParkedShareBar(share: asleep.share, endLabels: true)
            (Text("Asleep ") + Text("\(percent)%").fontWeight(.semibold)
             + Text(" of that time · \(ParkedText.span(asleep.asleepMinutes)) of \(ParkedText.span(asleep.coveredMinutes))")
                .foregroundStyle(HistoryTheme.secondary))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(Color.voltaTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Asleep \(percent) percent of parked time, \(ParkedText.spokenSpan(asleep.asleepMinutes)) of \(ParkedText.spokenSpan(asleep.coveredMinutes)). Recorded for \(asleep.coveredStops) of \(asleep.stops) stops.")
    }
}

// MARK: - Fastest drain

/// The stop with the highest per-day rate; opens that stop.
struct ParkedFastestTile: View {
    var stop: IdleSummary
    /// The car's average rate for the period; amber only at 1.5 times it or more.
    var average: Double?
    @Environment(\.units) private var units

    var body: some View {
        let text = ParkedText(units: units)
        let rate = ParkedTally([stop]).perDayKm ?? 0
        let notable = average.map { $0 > 0 && rate >= $0 * ParkedRules.notableRatio } ?? false
        let day = (stop.end ?? stop.start).formatted(.dateTime.month(.abbreviated).day())
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Fastest drain").voltaLabelStyle()
                (Text(text.rate(rate)).font(.system(.body, weight: .bold))
                    .foregroundStyle(notable ? HistoryTheme.amber : Color.voltaTextPrimary)
                 + Text("  \(stop.placeLabel) · \(day) · \(VoltaFormat.duration(stop.durationMin))")
                    .font(.footnote).foregroundStyle(HistoryTheme.secondary))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(HistoryTheme.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .voltaCardBackground(radius: 16)
        .contentShape(.rect(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fastest drain: \(text.spokenDistance(rate)) a day at \(stop.placeLabel), \(day), parked \(ParkedText.spokenSpan(stop.durationMin))\(notable ? ", well above this car's average" : "").")
        .accessibilityHint("Opens this stop")
    }
}
