import SwiftUI
import WidgetKit

// Lock Screen "glance" widgets: one value per widget on a transparent
// background (no gauge ring, no AccessoryWidgetBackground), so they sit on
// the wallpaper like the system's own small complications. Each metric is its
// own widget kind, so each gets its own page in the Lock Screen gallery.

enum GlanceMetric: String, CaseIterable, Sendable {
    case battery, range, charging, climate, security, today

    var kind: String { "VoltaGlance.\(rawValue)" }

    var displayName: String {
        switch self {
        case .battery: "Volta Battery Glance"
        case .range: "Volta Range"
        case .charging: "Volta Charging"
        case .climate: "Volta Cabin"
        case .security: "Volta Lock"
        case .today: "Volta Today"
        }
    }

    var summary: String {
        switch self {
        case .battery: "Battery level, no ring."
        case .range: "Estimated range left."
        case .charging: "Time to the charge limit, or plug state."
        case .climate: "Cabin temperature and climate."
        case .security: "Locked or unlocked, and Sentry Mode."
        case .today: "Distance driven today."
        }
    }

    /// Shown with no snapshot, and the default glyph for the metric.
    var baseSymbol: String {
        switch self {
        case .battery: "battery.75percent"
        case .range: "road.lanes"
        case .charging: "bolt.fill"
        case .climate: "thermometer.medium"
        case .security: "lock.fill"
        case .today: "steeringwheel"
        }
    }
}

/// What a glance shows for one snapshot at one moment. Pure, so every
/// family renders the same words.
struct GlanceContent: Equatable, Sendable {
    var symbol: String
    /// Big value, e.g. "78%", "270", "1h 34m".
    var value: String
    /// Small line under the value: a unit, a qualifier, or the data age when stale.
    var caption: String?
    /// The whole reading for `accessoryInline`.
    var inline: String

    static func make(_ metric: GlanceMetric, _ s: WidgetSnapshot?, now: Date) -> GlanceContent {
        guard let s else {
            return GlanceContent(symbol: metric.baseSymbol, value: "—", caption: nil, inline: "Volta")
        }
        let u = WidgetUnits(s)
        let r = VehicleReadout(s, now: now)
        var c: GlanceContent
        switch metric {
        case .battery:
            c = GlanceContent(symbol: r.batterySymbol, value: r.batteryPercent, caption: nil,
                              inline: r.batteryText)
        case .range:
            let known = s.rangeKm != nil
            c = GlanceContent(symbol: "road.lanes", value: u.distance(s.rangeKm),
                              caption: known ? u.distanceUnit : nil,
                              inline: known ? "\(u.distance(s.rangeKm)) \(u.distanceUnit) · \(r.batteryPercent)"
                                            : "Range — · \(r.batteryPercent)")
        case .charging:
            c = charging(s, r)
        case .climate:
            let on = s.climateOn == true
            var inline = "Cabin \(u.temperature(s.insideTempC))"
            if s.outsideTempC != nil { inline += " · Out \(u.temperature(s.outsideTempC))" }
            if on { inline += " · Climate on" }
            c = GlanceContent(symbol: on ? "fan.fill" : "thermometer.medium",
                              value: u.temperature(s.insideTempC), caption: on ? "On" : "Cabin",
                              inline: inline)
        case .security:
            let symbol: String = switch s.locked {
            case true?: "lock.fill"
            case false?: "lock.open.fill"
            case nil: "lock"
            }
            let value: String = switch s.locked {
            case true?: "Locked"
            case false?: "Open"
            case nil: "—"
            }
            let sentry = s.sentryMode == true
            c = GlanceContent(symbol: symbol, value: value, caption: sentry ? "Sentry" : nil,
                              inline: "\(r.lockText) · Sentry \(r.sentryText)")
        case .today:
            if let t = s.todayTotals(at: now) {
                let drives = t.driveCount == 1 ? "1 drive" : "\(t.driveCount) drives"
                c = GlanceContent(symbol: "steeringwheel", value: u.distance(t.distanceKm),
                                  caption: u.distanceUnit,
                                  inline: "Today \(u.distance(t.distanceKm)) \(u.distanceUnit) · \(drives)")
            } else {
                // Totals from another day are never shown as today's.
                c = GlanceContent(symbol: "steeringwheel", value: "—", caption: "Today", inline: "Today —")
            }
        }
        if s.isStale(at: now) {
            // Old data never reads as current: the age replaces the caption.
            let age = "\(WidgetFormat.shortAge(s.age(at: now))) ago"
            c.caption = age
            c.inline += " · \(age)"
        }
        return c
    }

    private static func charging(_ s: WidgetSnapshot, _ r: VehicleReadout) -> GlanceContent {
        let limit = s.chargeLimit.map { "to \($0)%" }
        switch r.charging {
        case .charging:
            if let left = r.shortTimeRemaining {
                return GlanceContent(symbol: "bolt.fill", value: left, caption: limit,
                                     inline: "Charging · \(left)\(limit.map { " \($0)" } ?? "") · \(r.batteryPercent)")
            }
            return GlanceContent(symbol: "bolt.fill", value: r.batteryPercent, caption: "Charging",
                                 inline: "Charging · \(r.batteryPercent)")
        case .complete:
            return GlanceContent(symbol: "checkmark.circle.fill", value: r.batteryPercent, caption: "Done",
                                 inline: "Charged · \(r.batteryPercent)")
        case .pluggedIn:
            return GlanceContent(symbol: "powerplug.fill", value: r.batteryPercent, caption: "Plugged",
                                 inline: "Plugged in · \(r.batteryPercent)")
        case .unplugged:
            return GlanceContent(symbol: "bolt.slash", value: r.batteryPercent, caption: nil,
                                 inline: "Unplugged · \(r.batteryPercent)")
        case .unknown:
            return GlanceContent(symbol: "bolt", value: r.batteryPercent, caption: nil,
                                 inline: "Charging unknown · \(r.batteryPercent)")
        }
    }
}

/// Shared configuration for every glance kind.
private func glanceConfiguration(_ metric: GlanceMetric) -> some WidgetConfiguration {
    StaticConfiguration(kind: metric.kind, provider: VoltaProvider()) { entry in
        GlanceView(metric: metric, entry: entry)
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(URL(string: "volta://dashboard"))
    }
    .configurationDisplayName(metric.displayName)
    .description(metric.summary)
    .supportedFamilies([.accessoryCircular, .accessoryInline])
}

/// Grouped so the main bundle stays within WidgetBundleBuilder's limit.
struct VoltaGlanceWidgets: WidgetBundle {
    var body: some Widget {
        VoltaStatusWidget()
        VoltaBatteryGlance()
        VoltaRangeGlance()
        VoltaChargingGlance()
        VoltaClimateGlance()
        VoltaSecurityGlance()
        VoltaTodayGlance()
    }
}

struct VoltaBatteryGlance: Widget {
    var body: some WidgetConfiguration { glanceConfiguration(.battery) }
}
struct VoltaRangeGlance: Widget {
    var body: some WidgetConfiguration { glanceConfiguration(.range) }
}
struct VoltaChargingGlance: Widget {
    var body: some WidgetConfiguration { glanceConfiguration(.charging) }
}
struct VoltaClimateGlance: Widget {
    var body: some WidgetConfiguration { glanceConfiguration(.climate) }
}
struct VoltaSecurityGlance: Widget {
    var body: some WidgetConfiguration { glanceConfiguration(.security) }
}
struct VoltaTodayGlance: Widget {
    var body: some WidgetConfiguration { glanceConfiguration(.today) }
}

struct GlanceView: View {
    @Environment(\.widgetFamily) private var family
    var metric: GlanceMetric
    var entry: VoltaEntry

    var body: some View {
        let c = GlanceContent.make(metric, entry.snapshot, now: entry.date)
        switch family {
        case .accessoryInline:
            Label(c.inline, systemImage: c.symbol)
        default:
            GlanceCircularView(content: c)
        }
    }
}

/// Glyph over value over caption, straight on the wallpaper.
struct GlanceCircularView: View {
    var content: GlanceContent
    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: content.symbol)
                .font(.system(size: 17, weight: .semibold))
                .widgetAccentable()
            Text(content.value)
                .font(.system(size: 16, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption = content.caption {
                Text(caption)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Status (rectangular, transparent)

/// Three-line car status on a transparent background: state, doors and
/// cabin, battery and range.
struct VoltaStatusWidget: Widget {
    static let kind = "VoltaStatusWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: VoltaProvider()) { entry in
            StatusRectangularView(s: entry.snapshot, now: entry.date)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "volta://dashboard"))
        }
        .configurationDisplayName("Volta Status")
        .description("State, doors, cabin and battery.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct StatusRectangularView: View {
    var s: WidgetSnapshot?
    var now: Date = .now

    var body: some View {
        if let s {
            let u = WidgetUnits(s)
            let r = VehicleReadout(s, now: now)
            let stale = s.isStale(at: now)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: stale ? "clock.badge.exclamationmark" : WidgetFormat.stateSymbol(s))
                    Text(s.vehicleName)
                    Text(stale ? "· \(WidgetFormat.shortAge(s.age(at: now))) ago" : "· \(WidgetFormat.stateText(s))")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 14, weight: .semibold))
                .widgetAccentable()
                HStack(spacing: 10) {
                    Label(r.lockText, systemImage: s.locked == false ? "lock.open.fill" : "lock.fill")
                    Label(u.temperature(s.insideTempC),
                          systemImage: s.climateOn == true ? "fan.fill" : "thermometer.medium")
                    if s.sentryMode == true {
                        Image(systemName: "shield.lefthalf.filled")
                    }
                }
                .font(.system(size: 13, weight: .medium))
                // A stale ETA would be outdated, so it only shows on fresh data.
                Label(!stale && r.charging == .charging ? "\(r.batteryText) · \(r.chargingText)" : r.batteryText,
                      systemImage: r.batterySymbol)
                    .font(.system(size: 13, weight: .medium))
            }
            .labelStyle(GlanceLabelStyle())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading) {
                Text("Volta").font(.headline)
                Text("Open the app to pair").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Tight icon + title spacing for the rectangular status rows.
private struct GlanceLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

#Preview("Glance circular", as: .accessoryCircular) {
    VoltaBatteryGlance()
} timeline: {
    VoltaEntry(date: .now, snapshot: .fixture())
    VoltaEntry(date: .now, snapshot: .fixtureCharging())
    VoltaEntry(date: .now, snapshot: .fixtureLowStale())
    VoltaEntry(date: .now, snapshot: nil)
}

#Preview("Charging glance", as: .accessoryCircular) {
    VoltaChargingGlance()
} timeline: {
    VoltaEntry(date: .now, snapshot: .fixtureCharging())
    VoltaEntry(date: .now, snapshot: .fixture())
}

#Preview("Glance inline", as: .accessoryInline) {
    VoltaClimateGlance()
} timeline: {
    VoltaEntry(date: .now, snapshot: .fixture())
    VoltaEntry(date: .now, snapshot: .fixtureLowStale())
}

#Preview("Status", as: .accessoryRectangular) {
    VoltaStatusWidget()
} timeline: {
    VoltaEntry(date: .now, snapshot: .fixture())
    VoltaEntry(date: .now, snapshot: .fixtureCharging())
    VoltaEntry(date: .now, snapshot: .fixtureLowStale())
    VoltaEntry(date: .now, snapshot: nil)
}
