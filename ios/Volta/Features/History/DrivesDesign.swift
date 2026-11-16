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
                        .strokeBorder(.white.opacity(0.05), lineWidth: 1)
                }
        }
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Score

/// Open 270° dial with the score inside, tinted by band (`DriveScoreTint`)
/// everywhere: the Drives header and every card.
struct ScoreDial: View {
    var score: Int?
    var size: CGFloat = 40
    var caption: String? = nil
    private var value: Int? { score.flatMap { (0...100).contains($0) ? $0 : nil } }
    private var line: CGFloat { max(2.5, size * 0.06) }

    var body: some View {
        let tint = DriveScoreBand.tint(value)
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(.white.opacity(0.1), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(135))
            if let value {
                let fraction = Double(value) / 100
                Circle().trim(from: 0, to: 0.75 * fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(135))
            }
            VStack(spacing: size * 0.02) {
                Text(value.map(String.init) ?? "–")
                    .font(.system(size: size * (caption == nil ? 0.36 : 0.32), weight: .semibold))
                    .monospacedDigit().foregroundStyle(.white)
                if let caption {
                    Text(caption).font(.system(size: max(8, size * 0.1), weight: .semibold)).tracking(1.2)
                        .textCase(.uppercase).foregroundStyle(HistoryTheme.secondary)
                }
            }
        }
        .frame(width: size, height: size)
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
            .stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
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
    static let size = CGSize(width: 72, height: 48)

    var body: some View {
        Canvas { ctx, size in
            let runs = DriveRouteSegments.normalized(points, in: size, inset: 4)
            let lines = runs.filter { $0.count > 1 }
            var path = Path()
            for run in lines { path.move(to: run[0]); run.dropFirst().forEach { path.addLine(to: $0) } }
            ctx.stroke(path, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let valid = runs.flatMap { $0 }
            guard let start = valid.first, let end = valid.last else { return }
            if hypot(end.x - start.x, end.y - start.y) < 4 {
                RouteEndpointMarker.draw(.both, in: &ctx, at: start, size: 7)
            } else {
                RouteEndpointMarker.draw(.end, in: &ctx, at: end, size: 7)
                RouteEndpointMarker.draw(.start, in: &ctx, at: start, size: 7)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
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
                    Text(VoltaFormat.number(units.distanceValue(km: totals.distanceKm), digits: 0))
                        .font(.system(size: 60, weight: .bold)).tracking(-1)
                        .foregroundStyle(.white).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    Text(units.distanceUnit).font(.system(size: 17, weight: .regular)).foregroundStyle(HistoryTheme.secondary)
                }
                Spacer(minLength: 0)
                VStack(spacing: 4) {
                    ScoreDial(score: totals.score, size: 61)
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
                    Text(item.text).font(.system(size: textSize, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
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
                    .foregroundStyle(.white.opacity(0.85))
                Text(group.title).font(.system(size: 16, weight: .medium)).foregroundStyle(.white).lineLimit(1)
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

struct DriveCard: View {
    var drive: DriveSummary
    var showsDate = false
    @Environment(\.units) private var units
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(AppModel.self) private var model: AppModel?

    private var cost: String? {
        let rate = DrivePricing.rate(drive, home: model?.settings.rates.homeTripRate)
        return rate.flatMap { rate in rate.cost(energyKwh: drive.costableEnergyKwh).map { VoltaFormat.money($0, currency: rate.currency) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // Names take what's left and truncate; the sketch keeps its box.
                itinerary.frame(maxWidth: .infinity, alignment: .leading)
                if !typeSize.isAccessibilitySize, drive.drawableRoute.count > 1 {
                    RouteSketch(points: drive.drawableRoute)
                }
                VStack(alignment: .trailing, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(VoltaFormat.number(units.distanceValue(km: drive.distanceKm)))
                            .font(.system(size: 21, weight: .bold)).monospacedDigit()
                        Text(units.distanceUnit.uppercased()).scaledFont(11, weight: .semibold).tracking(0.8).foregroundStyle(HistoryTheme.secondary)
                    }
                    .foregroundStyle(.white)
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
                .fixedSize()
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
                ScoreDial(score: drive.efficiencyScore, size: 27)
            }
            .padding(.leading, 18).padding(.trailing, 16)
            .padding(.top, 14)
        }
        .padding(.top, 14).padding(.bottom, 13)
        .driveSurface(radius: 18)
        .accessibilityElement(children: .combine)
    }

    private var itinerary: some View {
        VStack(alignment: .leading, spacing: 0) {
            place(drive.startPlace, marker: .start)
            Rectangle().fill(HistoryTheme.tertiary.opacity(0.7)).frame(width: 1, height: 5)
                .padding(.leading, 4.5).padding(.vertical, 0.5)
            place(drive.endPlace, marker: .end)
        }
    }

    private func place(_ name: String, marker: RouteEndpoint) -> some View {
        HStack(spacing: 12) {
            RouteEndpointMarker(kind: marker, size: 9)
            Text(name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(height: 22)
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
            Image(systemName: systemImage).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                .lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
        }
        .padding(.leading, 13).padding(.trailing, 14)
        .frame(height: 42)
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .contentShape(.rect(cornerRadius: 17))
    }
}
