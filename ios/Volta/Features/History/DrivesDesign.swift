import SwiftUI

// Drives tab visual language: quiet surfaces, one hero numeral, routes as light.
// Everything here is pure drawing from the row payload; no tiles, no lookups.

enum DriveScoreBand {
    static func tint(_ score: Int?) -> Color {
        guard let score else { return HistoryTheme.secondary }
        return score >= 85 ? HistoryTheme.mint : score >= 70 ? HistoryTheme.blue : HistoryTheme.amber
    }
}

extension HistoryTheme {
    /// Softer than `green`; route starts and high scores.
    static let mint = Color.voltaMint
    static let routeGradient = LinearGradient(colors: [mint, blue], startPoint: .leading, endPoint: .trailing)
}

// MARK: - Surface

extension View {
    /// Card fill lit from above: a faint top highlight instead of a flat hairline.
    func driveSurface(radius: CGFloat = 24) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Color.voltaCardTop, Color.voltaCard], startPoint: .top, endPoint: .bottom))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.11), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
        }
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Score

/// Open 270° dial; the arc brightens toward its tip.
struct ScoreDial: View {
    var score: Int?
    var size: CGFloat = 40
    var caption: String? = nil
    private var value: Int? { score.flatMap { (0...100).contains($0) ? $0 : nil } }
    private var line: CGFloat { max(2.5, size * 0.055) }

    var body: some View {
        let tint = DriveScoreBand.tint(value)
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(.white.opacity(0.07), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(135))
            if let value {
                Circle().trim(from: 0, to: 0.75 * Double(value) / 100)
                    .stroke(AngularGradient(colors: [tint.opacity(0.35), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(270 * Double(value) / 100)),
                            style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .shadow(color: tint.opacity(size > 60 ? 0.45 : 0.25), radius: size > 60 ? 8 : 3)
            }
            VStack(spacing: size * 0.02) {
                Text(value.map(String.init) ?? "–")
                    .font(.system(size: size * (caption == nil ? 0.36 : 0.34), weight: .semibold, design: .rounded))
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

/// The drive's own path, drawn as a faint luminous watermark.
struct RouteWatermark: View {
    var points: [DriveRoutePoint]
    var opacity: Double = 0.5

    var body: some View {
        GeometryReader { geometry in
            let runs = DriveRouteSegments.normalized(points, in: geometry.size, inset: 16)
            let path = Path { path in
                for run in runs where run.count > 1 {
                    path.move(to: run[0]); run.dropFirst().forEach { path.addLine(to: $0) }
                }
            }
            ZStack {
                path.stroke(HistoryTheme.routeGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    .blur(radius: 7).opacity(0.45)
                path.stroke(HistoryTheme.routeGradient, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                if let start = runs.first?.first {
                    Circle().fill(HistoryTheme.mint).frame(width: 5, height: 5).position(start)
                }
                if let end = runs.last?.last, runs.flatMap({ $0 }).count > 1 {
                    Circle().fill(HistoryTheme.blue).frame(width: 5, height: 5).position(end)
                        .shadow(color: HistoryTheme.blue, radius: 4)
                }
            }
            .opacity(opacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Hero

struct DrivesHero: View {
    var scope: String
    var totals: DriveTotals
    var durationMin: Double
    var partial: Bool
    var daily: [DailyDistance]
    @Environment(\.units) private var units

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(scope).voltaLabelStyle(color: HistoryTheme.tertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(VoltaFormat.number(units.distanceValue(km: totals.distanceKm), digits: 0))
                            .font(.system(size: 84, weight: .bold)).fontWidth(.expanded).tracking(-2)
                            .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.45)
                        Text(units.distanceUnit).font(.system(size: 20, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                    }
                }
                Spacer(minLength: 0)
                ScoreDial(score: totals.score, size: 86, caption: "Score").padding(.trailing, 4)
            }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader).accessibilityIdentifier("screen.drives")

            HStack(spacing: 0) {
                stat(VoltaFormat.duration(durationMin), "Driving")
                divider
                stat("\(totals.drives)\(partial ? "+" : "")", totals.drives == 1 && !partial ? "Drive" : "Drives")
                divider
                stat(totals.energyUsedKwh.value.map { VoltaFormat.number($0) } ?? "—", "kWh")
                divider
                stat(totals.efficiencyWhPerKm.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) } ?? "—", units.efficiencyUnit)
            }
            if daily.contains(where: { $0.km > 0 }) { DailyRhythm(days: daily) }
        }
    }

    private var divider: some View { Rectangle().fill(HistoryTheme.hairline).frame(width: 1, height: 28) }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.system(size: 10, weight: .semibold)).tracking(1).textCase(.uppercase).foregroundStyle(HistoryTheme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, caption == "Driving" ? 0 : 12)
        .accessibilityElement(children: .combine)
    }
}

struct DailyDistance: Hashable {
    var day: Date
    var km: Double

    /// The last `days` calendar days ending today, zero-filled.
    static func series(_ drives: [DriveSummary], days: Int = 14, now: Date = .now, calendar: Calendar = .current) -> [DailyDistance] {
        let today = calendar.startOfDay(for: now)
        let totals = Dictionary(grouping: drives, by: { calendar.startOfDay(for: $0.start) }).mapValues { $0.reduce(0) { $0 + $1.distanceKm } }
        return (0..<days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { DailyDistance(day: $0, km: totals[$0] ?? 0) }
        }
    }
}

/// Fourteen-day bar strip; today is lit.
struct DailyRhythm: View {
    var days: [DailyDistance]
    @Environment(\.units) private var units

    var body: some View {
        let peak = max(days.map(\.km).max() ?? 0, 0.1)
        let driven = days.filter { $0.km > 0 }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    let isToday = index == days.count - 1
                    if index > 0 { Spacer(minLength: 2) }
                    Capsule()
                        .fill(day.km == 0 ? AnyShapeStyle(.white.opacity(0.1))
                              : isToday ? AnyShapeStyle(LinearGradient(colors: [HistoryTheme.mint, HistoryTheme.blue], startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.16)], startPoint: .top, endPoint: .bottom)))
                        .frame(width: day.km == 0 ? 4 : 7, height: day.km == 0 ? 4 : max(7, 34 * day.km / peak))
                        .shadow(color: isToday && day.km > 0 ? HistoryTheme.mint.opacity(0.5) : .clear, radius: 5)
                }
            }
            .frame(height: 34, alignment: .bottom)
            HStack {
                Text("Last 14 days")
                Spacer()
                Text("\(units.formatDistance(driven.reduce(0) { $0 + $1.km } / Double(max(driven.count, 1)))) per driving day")
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Distance per day, last 14 days")
    }
}

// MARK: - Day header

struct DriveDayHeader: View {
    var group: DayGroup<DriveSummary>
    @Environment(\.units) private var units

    var body: some View {
        HStack(spacing: 10) {
            Text(group.day.formatted(.dateTime.day()))
                .font(.system(size: 11, weight: .bold)).monospacedDigit()
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.05), in: .rect(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .foregroundStyle(HistoryTheme.secondary)
            Text(group.title).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
            Spacer(minLength: 8)
            Text("\(group.items.count) \(group.items.count == 1 ? "drive" : "drives") · \(units.formatDistance(group.items.reduce(0) { $0 + $1.distanceKm }))")
                .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            VStack(spacing: 0) {
                HistoryTheme.background
                LinearGradient(colors: [HistoryTheme.background, HistoryTheme.background.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 14)
            }
            .padding(.horizontal, -HistoryTheme.gutter).padding(.bottom, -14)
        }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Card

struct DriveCard: View {
    var drive: DriveSummary
    var showsDate = false
    @Environment(\.units) private var units
    @Environment(AppModel.self) private var model: AppModel?

    private var rate: Double { model?.settings.electricityRate ?? 0.20 }
    private var cost: String? {
        DrivePricing.cost(drive, fallback: rate).map { VoltaFormat.money($0, currency: DrivePricing.rate(drive, fallback: rate).currency) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                itinerary
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(VoltaFormat.number(units.distanceValue(km: drive.distanceKm)))
                            .font(.system(size: 30, weight: .bold)).fontWidth(.expanded).tracking(-0.8).monospacedDigit()
                        Text(units.distanceUnit.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(HistoryTheme.secondary)
                    }
                    .foregroundStyle(.white)
                    HStack(spacing: 5) {
                        Text(drive.start.historyTime)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(HistoryTheme.tertiary)
                        Text(drive.end?.historyTime ?? "Now")
                    }
                    .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                    if showsDate {
                        Text(drive.start.formatted(.dateTime.month(.abbreviated).day().year())).font(.system(size: 11, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
                    }
                }
            }
            .padding(.bottom, 16)
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    metrics(compact: false)
                    metrics(compact: true)
                }
                Spacer(minLength: 8)
                ScoreDial(score: drive.efficiencyScore, size: 38)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
        .background {
            RouteWatermark(points: drive.route ?? [], opacity: 0.42)
                .padding(.leading, 130).padding(.trailing, 90).padding(.top, 4).padding(.bottom, 44)
                .mask(RadialGradient(colors: [.black, .black.opacity(0.6), .clear], center: .center, startRadius: 10, endRadius: 120))
        }
        .driveSurface()
        .accessibilityElement(children: .combine)
    }

    private var itinerary: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(HistoryTheme.mint).frame(width: 8, height: 8).padding(.top, 7)
                Rectangle().fill(LinearGradient(colors: [HistoryTheme.mint.opacity(0.6), HistoryTheme.blue.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 1.5).frame(maxHeight: .infinity).padding(.vertical, 4)
                Circle().fill(HistoryTheme.blue).frame(width: 8, height: 8).padding(.bottom, 7)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text(drive.startPlace)
                Text(drive.endPlace)
            }
            .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.75)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func metrics(compact: Bool) -> some View {
        HStack(spacing: 8) {
            metric("clock", VoltaFormat.duration(drive.durationMin))
            dot
            metric("leaf", drive.efficiencyWhPerKm.map { compact ? VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) : units.formatEfficiency($0) } ?? "—")
            if let cost { dot; metric("creditcard", cost) }
        }
    }

    private var dot: some View { Circle().fill(HistoryTheme.tertiary).frame(width: 2.5, height: 2.5) }

    private func metric(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
            Text(text).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.78))
        }
        .lineLimit(1).fixedSize()
    }
}

// MARK: - Shortcuts

struct DriveShortcut: View {
    var title: String
    var systemImage: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 13, weight: .semibold)).foregroundStyle(HistoryTheme.mint)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold)).foregroundStyle(HistoryTheme.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(.white.opacity(0.035), in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}
