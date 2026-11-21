import SwiftUI

// Drives tab in the Wattly language: flat charcoal cards, one big distance,
// open score dials, routes as a faint grey watermark. Pure drawing from the
// row payload; no tiles, no lookups.

enum DriveScoreBand {
    static func tint(_ score: Int?) -> Color { DriveScoreTint.color(score) }
}

// MARK: - Surface

extension View {
    /// Flat card fill with a faint edge.
    func driveSurface(radius: CGFloat = 24) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(HistoryTheme.card)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.voltaInk.opacity(0.05), lineWidth: 1)
                }
        }
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Score

/// Open 270° dial of the drive score (0–100), filled from its start, with the
/// score inside, tinted by band (`DriveScoreTint`: green high, ink middle,
/// amber low) everywhere: the Drives header and every card. The arc settles
/// to its value as it appears.
///
/// `endLabels` writes 0 and 100 at the arc's ends. Card dials (27 pt) are too
/// small to carry them, so cards label the dial "Score" beside it instead and
/// the larger dials (Drives header, drive detail) carry the ends.
struct ScoreDial: View {
    var score: Int?
    var size: CGFloat = 40
    var caption: String? = nil
    var endLabels = false
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var value: Int? { score.flatMap { (0...100).contains($0) ? $0 : nil } }
    private var line: CGFloat { max(2.5, size * 0.06) }

    var body: some View {
        let tint = DriveScoreBand.tint(value)
        let shown = settled || reduceMotion
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color.voltaInk.opacity(0.1), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(135))
            if let value {
                let fraction = Double(value) / 100
                Circle().trim(from: 0, to: 0.75 * fraction * (shown ? 1 : 0))
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(135))
            }
            VStack(spacing: size * 0.02) {
                Group {
                    if size >= 50, let value {
                        RollingNumber(value: Double(value)) { String(Int($0.rounded())) }
                    } else {
                        Text(value.map(String.init) ?? "—")
                    }
                }
                .font(.system(size: size * (caption == nil ? 0.36 : 0.32), weight: .semibold))
                .monospacedDigit().foregroundStyle(.voltaTextPrimary)
                if let caption {
                    Text(caption).font(.system(size: max(11, size * 0.12), weight: .medium))
                        .foregroundStyle(HistoryTheme.secondary)
                }
            }
            if endLabels {
                // Under the arc's two ends, in the dial's open gap.
                HStack {
                    Text("0")
                    Spacer(minLength: 0)
                    Text("100")
                }
                .font(.system(size: max(9, size * 0.15), weight: .medium))
                .monospacedDigit()
                .foregroundStyle(HistoryTheme.tertiary)
                .frame(width: size * 0.9)
                .offset(y: size * 0.42)
            }
        }
        .frame(width: size, height: size)
        .animation(VoltaMotion.animation(VoltaMotion.settle, reduceMotion: reduceMotion), value: value)
        .onAppear {
            guard !settled else { return }
            withAnimation(VoltaMotion.animation(VoltaMotion.settle.delay(0.1), reduceMotion: reduceMotion)) { settled = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "Drive score \($0) of 100" } ?? "Drive score unavailable")
    }
}

// MARK: - Route

/// The drive's own path as a thin grey line, no glow.
struct RouteWatermark: View {
    var points: [DriveRoutePoint]
    var opacity: Double = 0.3

    var body: some View {
        GeometryReader { geometry in
            // Lines only: single-point runs would read as scattered dots.
            let runs = DriveRouteSegments.normalized(points, in: geometry.size, inset: 16).filter { $0.count > 1 }
            Path { path in
                for run in runs {
                    path.move(to: run[0]); run.dropFirst().forEach { path.addLine(to: $0) }
                }
            }
            .stroke(Color.voltaInk, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .opacity(opacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A drive's path in its own small box on a card: a thin white line fitted
/// with a 4 pt inset, a ring at the start and a dot at the end.
struct RouteSketch: View {
    var points: [DriveRoutePoint]
    var size = RouteSketch.size
    static let size = CGSize(width: 72, height: 48)
    /// On cards narrower than 390 pt, so the place names keep their room.
    static let compact = CGSize(width: 56, height: 40)

    /// The last step when names don't fit on one line beside `compact`.
    static let small = CGSize(width: 44, height: 32)

    static func size(forCardWidth width: CGFloat) -> CGSize { width > 0 && width < 390 ? compact : size }

    var body: some View {
        Canvas { ctx, size in
            let runs = DriveRouteSegments.normalized(points, in: size, inset: 4)
            let lines = runs.filter { $0.count > 1 }
            var path = Path()
            for run in lines { path.move(to: run[0]); run.dropFirst().forEach { path.addLine(to: $0) } }
            ctx.stroke(path, with: .color(Color.voltaInk.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let valid = runs.flatMap { $0 }
            guard let start = valid.first, let end = valid.last else { return }
            if hypot(end.x - start.x, end.y - start.y) < 4 {
                RouteEndpointMarker.draw(.both, in: &ctx, at: start, size: 7)
            } else {
                RouteEndpointMarker.draw(.end, in: &ctx, at: end, size: 7)
                RouteEndpointMarker.draw(.start, in: &ctx, at: start, size: 7)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Hero

/// Wattly list metrics, in points on a 402 pt wide phone.
enum DrivesLayout {
    /// Text column inset from the screen edge.
    static let margin: CGFloat = 28
    /// Card inset from the screen edge.
    static let cardInset: CGFloat = 16
}

extension UnitPreferences {
    /// Efficiency with one decimal, as on the drives list ("204.8 Wh/mi").
    func formatEfficiencyPrecise(_ whPerKm: Double?) -> String {
        guard let whPerKm else { return "—" }
        return "\(VoltaFormat.number(efficiencyValue(whPerKm: whPerKm), digits: 1)) \(efficiencyUnit)"
    }
}

struct DrivesHero: View {
    /// "12 drives", or "30 drives loaded" while older pages are still on the
    /// server: the totals cover only the pages fetched so far.
    static func countText(_ count: Int, partial: Bool) -> String {
        "\(count) \(count == 1 ? "drive" : "drives")\(partial ? " loaded" : "")"
    }

    /// What the totals cover, e.g. "Loaded drives · partial"; read aloud with the hero.
    var scope: String
    var totals: DriveTotals
    var durationMin: Double
    /// Estimated cost (`DrivePricing.total`): display string and coverage note.
    /// "—" (no rate applies) drops the item rather than showing a bare dash.
    var cost: (display: String, note: String?) = ("—", nil)
    var partial: Bool
    @Environment(\.units) private var units

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RollingNumber(value: units.distanceValue(km: totals.distanceKm)) { VoltaFormat.number($0, digits: 0) }
                        .font(.system(size: 60, weight: .bold)).tracking(-1)
                        .foregroundStyle(.voltaTextPrimary).lineLimit(1).minimumScaleFactor(0.5)
                    Text(units.distanceUnit).font(.system(size: 17, weight: .regular)).foregroundStyle(HistoryTheme.secondary)
                }
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    ScoreDial(score: totals.score, size: 61, endLabels: true)
                    Text("Drive score").scaledFont(11, weight: .medium).foregroundStyle(HistoryTheme.secondary)
                        .lineLimit(1).fixedSize()
                        .accessibilityHidden(true)
                }
                .padding(.trailing, -3)
            }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            .accessibilityLabel(scope)
            .accessibilityIdentifier("screen.drives")

            VStack(alignment: .leading, spacing: 6) {
                HistoryFlowStats(items: [
                    ("clock", VoltaFormat.duration(durationMin)),
                    ("road.lanes", DrivesHero.countText(totals.drives, partial: partial)),
                ], textSize: 14, iconSize: 12.5, spacing: 11, iconSpacing: 8)
                // Energy and efficiency come only from drives with recorded energy
                // (DriveTotals); cost shows only when a known rate applies.
                HistoryFlowStats(items: [
                    ("bolt.fill", totals.energyUsedKwh.value.map { VoltaFormat.energy($0) } ?? "— kWh"),
                    ("leaf.fill", units.formatEfficiencyPrecise(totals.efficiencyWhPerKm)),
                ] + (cost.display == "—" ? [] : [("creditcard.fill", cost.display)]),
                textSize: 14, iconSize: 12.5, spacing: 11, iconSpacing: 8)
            }
        }
    }
}

/// One row of hero stats: neutral icon, white value, dot separators. Green
/// is kept for energy in and efficient driving.
struct HistoryFlowStats: View {
    var items: [(icon: String, text: String)]
    var textSize: CGFloat = 20
    var iconSize: CGFloat = 16
    var spacing: CGFloat = 12
    var iconSpacing: CGFloat = 10

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Circle().fill(HistoryTheme.tertiary).frame(width: 3, height: 3) }
                HStack(spacing: iconSpacing) {
                    Image(systemName: item.icon).font(.system(size: iconSize, weight: .semibold)).foregroundStyle(HistoryTheme.secondary)
                    Text(item.text).font(.system(size: textSize, weight: .semibold)).monospacedDigit().foregroundStyle(.voltaTextPrimary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct DailyDistance: Hashable {
    var day: Date
    var km: Double
    /// Today.
    var isToday = false

    /// One entry per day in `window`, oldest first. A day inside the window
    /// with no drives is a real zero; days outside it are not returned.
    static func series(_ drives: [DriveSummary], window: HistoryDayWindow, calendar: Calendar = .current) -> [DailyDistance] {
        HistoryRhythmDay.series(drives, date: \.start, value: \.distanceKm, window: window, calendar: calendar)
            .map { DailyDistance(day: $0.day, km: $0.value, isToday: $0.isToday) }
    }
}

// MARK: - Day header

struct DriveDayHeader: View {
    var group: DayGroup<DriveSummary>
    /// Side bars the pinned header runs under; its text keeps clear of them.
    var sides = EdgeInsets()
    @Environment(\.units) private var units

    var body: some View {
        let count = group.items.count
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(group.day.formatted(.dateTime.day()))
                    .font(.system(size: 8, weight: .bold)).monospacedDigit()
                    .frame(width: 13, height: 12, alignment: .bottom).padding(.bottom, 1)
                    .overlay(alignment: .top) { Rectangle().frame(height: 1.5).padding(.horizontal, 1.5).padding(.top, 1.5) }
                    .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(lineWidth: 1.2))
                    .foregroundStyle(Color.voltaInk.opacity(0.85))
                Text(group.title).font(.system(size: 16, weight: .medium)).foregroundStyle(.voltaTextPrimary).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(count) \(count == 1 ? "drive" : "drives") · \(units.formatDistance(group.items.reduce(0) { $0 + $1.distanceKm }))")
                    .font(.system(size: 13)).monospacedDigit().foregroundStyle(HistoryTheme.secondary).lineLimit(1)
            }
            .padding(.horizontal, DrivesLayout.margin)
            .padding(.top, 14).padding(.bottom, 12)
            .voltaReadableWidth()
            .padding(.leading, sides.leading).padding(.trailing, sides.trailing)
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .background(HistoryTheme.background)
        .padding(.bottom, 15)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Card

/// A drive or roadtrip card's top row: place names, route sketch, and the
/// trailing distance column, fitted in order: names on one line each beside
/// the card's sketch (56 × 40 under 390 pt, else 72 × 48); names on one line
/// each beside a 44 × 32 sketch with 8 pt gaps; names on up to two lines
/// beside that small sketch. Names stay 17 pt semibold in every step and
/// are never truncated. Accessibility sizes drop the sketch.
struct CardHeaderRow<Names: View, Trailing: View>: View {
    var points: [DriveRoutePoint]
    var cardWidth: CGFloat
    /// Space above the sketch, to line it up with the names.
    var sketchTop: CGFloat = 0
    /// The names, on one line each (`oneLine`) or wrapping to two.
    @ViewBuilder var names: (_ oneLine: Bool) -> Names
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize || points.count < 2 {
            row(oneLine: false, sketch: nil, gap: 12)
        } else {
            ViewThatFits(in: .horizontal) {
                row(oneLine: true, sketch: RouteSketch.size(forCardWidth: cardWidth), gap: 12)
                row(oneLine: true, sketch: RouteSketch.small, gap: 8)
                row(oneLine: false, sketch: RouteSketch.small, gap: 8)
            }
        }
    }

    private func row(oneLine: Bool, sketch: CGSize?, gap: CGFloat) -> some View {
        HStack(alignment: .top, spacing: gap) {
            names(oneLine).frame(maxWidth: .infinity, alignment: .leading)
            if let sketch { RouteSketch(points: points, size: sketch).padding(.top, sketchTop) }
            trailing().fixedSize()
        }
    }
}

/// A place name on a card: 17 pt semibold, on one line (sized to fit, so
/// `ViewThatFits` sees its full width) or wrapping to two.
struct CardPlaceName: View {
    var name: String
    var oneLine: Bool

    var body: some View {
        if oneLine {
            Text(name).scaledFont(17, weight: .semibold, relativeTo: .body).lineLimit(1).fixedSize()
        } else {
            Text(name).scaledFont(17, weight: .semibold, relativeTo: .body)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DriveCard: View {
    var drive: DriveSummary
    var showsDate = false
    @Environment(\.units) private var units
    @Environment(AppModel.self) private var model: AppModel?
    @State private var width: CGFloat = 0

    private var cost: String? {
        let rate = DrivePricing.rate(drive, home: model?.settings.rates.homeTripRate)
        return rate.flatMap { rate in rate.cost(energyKwh: drive.costableEnergyKwh).map { VoltaFormat.money($0, currency: rate.currency) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeaderRow(points: drive.drawableRoute, cardWidth: width) { oneLine in
                itinerary(oneLine: oneLine)
            } trailing: {
                VStack(alignment: .trailing, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(VoltaFormat.number(units.distanceValue(km: drive.distanceKm)))
                            .font(.system(size: 21, weight: .bold)).monospacedDigit()
                        Text(units.distanceUnit).scaledFont(13, weight: .regular).foregroundStyle(HistoryTheme.secondary)
                    }
                    .foregroundStyle(.voltaTextPrimary)
                    HStack(spacing: 5) {
                        Text(drive.start.historyTime)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .medium))
                        Text(drive.end?.historyTime ?? "Now")
                    }
                    .font(.system(size: 13)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                    if showsDate {
                        Text(drive.start.formatted(.dateTime.month(.abbreviated).day().year())).scaledFont(11).foregroundStyle(HistoryTheme.tertiary)
                    }
                }
                .padding(.top, 1)
            }
            .padding(.leading, 18).padding(.trailing, 16)
            .padding(.bottom, 16)
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1).padding(.horizontal, 13)
            HStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    metrics(compact: false)
                    metrics(compact: true)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Text("Score").scaledFont(11, weight: .medium).foregroundStyle(HistoryTheme.tertiary)
                        .accessibilityHidden(true)
                    ScoreDial(score: drive.efficiencyScore, size: 27)
                }
                .fixedSize()
            }
            .padding(.leading, 18).padding(.trailing, 16)
            .padding(.top, 14)
        }
        .padding(.top, 14).padding(.bottom, 13)
        .driveSurface(radius: 18)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .combine)
    }

    private func itinerary(oneLine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            place(drive.startPlace, marker: .start, oneLine: oneLine)
            Rectangle().fill(HistoryTheme.tertiary.opacity(0.7)).frame(width: 1, height: 5)
                .padding(.leading, 4.5).padding(.vertical, 0.5)
            place(drive.endPlace, marker: .end, oneLine: oneLine)
        }
    }

    /// Both names at one size (17 pt semibold, scaling with Dynamic Type);
    /// a long name wraps to a second line, never shrinks or truncates.
    private func place(_ name: String, marker: RouteEndpoint, oneLine: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            RouteEndpointMarker(kind: marker, size: 9)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
            CardPlaceName(name: name, oneLine: oneLine).foregroundStyle(.voltaTextPrimary)
        }
        .frame(minHeight: 22)
    }

    private func metrics(compact: Bool) -> some View {
        HStack(spacing: 8) {
            metric("clock", VoltaFormat.duration(drive.durationMin))
            if let efficiency = drive.displayEfficiencyWhPerKm {
                dot
                metric("leaf.fill", compact ? VoltaFormat.number(units.efficiencyValue(whPerKm: efficiency), digits: 0) : units.formatEfficiencyPrecise(efficiency))
            }
            if let cost { dot; metric("creditcard.fill", cost) }
        }
    }

    private var dot: some View { Circle().fill(HistoryTheme.tertiary).frame(width: 3, height: 3) }

    private func metric(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium))
            Text(text).font(.system(size: 13)).monospacedDigit()
        }
        .foregroundStyle(HistoryTheme.secondary)
        .lineLimit(1).fixedSize()
    }
}

// MARK: - Shortcuts

struct DriveShortcut: View {
    var title: String
    var systemImage: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.voltaInk.opacity(0.85))
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.voltaTextPrimary)
                .lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
        }
        .padding(.leading, 13).padding(.trailing, 14)
        .frame(height: 42)
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Color.voltaInk.opacity(0.1), lineWidth: 1))
        .contentShape(.rect(cornerRadius: 17))
    }
}
