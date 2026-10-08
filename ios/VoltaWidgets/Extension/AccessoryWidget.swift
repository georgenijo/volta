import SwiftUI
import WidgetKit

/// Lock Screen (and StandBy / watch Smart Stack-style) accessory widgets.
struct VoltaAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotStore.accessoryWidgetKind, provider: VoltaProvider()) { entry in
            VoltaAccessoryView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "volta://dashboard"))
        }
        .configurationDisplayName("Volta Battery")
        .description("Battery and range at a glance.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct VoltaAccessoryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: VoltaEntry

    var body: some View {
        switch family {
        case .accessoryRectangular: AccessoryRectangularView(s: entry.snapshot, now: entry.date)
        case .accessoryInline: AccessoryInlineView(s: entry.snapshot, now: entry.date)
        default: AccessoryCircularView(s: entry.snapshot, now: entry.date)
        }
    }
}

/// Stale snapshots swap the state glyph for a clock so old data never reads as current.
private let staleSymbol = "clock.badge.exclamationmark"

struct AccessoryCircularView: View {
    var s: WidgetSnapshot?
    var now: Date = .now
    var body: some View {
        if let s {
            let stale = s.isStale(at: now)
            Gauge(value: Double(s.batteryLevel), in: 0...100) {
                Image(systemName: stale ? staleSymbol : s.isCharging ? "bolt.fill" : "car.fill")
            } currentValueLabel: {
                Text("\(s.batteryLevel)")
                    .font(.system(size: 18, weight: .heavy))
            }
            .gaugeStyle(.accessoryCircular)
            .widgetAccentable()
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "bolt.car").font(.system(size: 20, weight: .medium))
            }
        }
    }
}

struct AccessoryRectangularView: View {
    var s: WidgetSnapshot?
    var now: Date = .now
    var body: some View {
        if let s {
            let u = WidgetUnits(s)
            let stale = s.isStale(at: now)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: stale ? staleSymbol : WidgetFormat.stateSymbol(s))
                    Text(s.vehicleName)
                    if stale {
                        // e.g. "· 3h ago": the ETA would be outdated, so show the data age instead.
                        Text("· \(WidgetFormat.shortAge(s.age(at: now))) ago")
                    } else if s.isCharging, let m = s.minutesToFull {
                        Text("· \(WidgetFormat.minutes(m))")
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .widgetAccentable()
                .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(s.batteryLevel)%").font(.system(size: 22, weight: .heavy))
                    Text("\(u.distance(s.rangeKm)) \(u.distanceUnit)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                AccessoryBar(fraction: Double(s.batteryLevel) / 100,
                             marker: s.chargeLimit.map { Double($0) / 100 })
            }
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

/// Monochrome-friendly capacity bar with a charge-limit tick.
struct AccessoryBar: View {
    var fraction: Double
    var marker: Double?
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white)
                    .frame(width: max(5, geo.size.width * min(1, max(0, fraction))))
                    .widgetAccentable()
                if let marker {
                    Rectangle().fill(.white.opacity(0.8)).frame(width: 1.5, height: 9)
                        .offset(x: geo.size.width * min(1, max(0, marker)) - 0.75)
                }
            }
        }
        .frame(height: 5)
    }
}

struct AccessoryInlineView: View {
    var s: WidgetSnapshot?
    var now: Date = .now
    var body: some View {
        if let s {
            let u = WidgetUnits(s)
            let stale = s.isStale(at: now)
            let symbol = stale ? staleSymbol : s.isCharging ? "bolt.fill" : "car.fill"
            let age = stale ? " · \(WidgetFormat.shortAge(s.age(at: now))) ago" : ""
            ViewThatFits {
                Label("\(s.vehicleName) \(s.batteryLevel)% · \(u.distance(s.rangeKm)) \(u.distanceUnit)\(age)",
                      systemImage: symbol)
                Label("\(s.batteryLevel)% · \(u.distance(s.rangeKm)) \(u.distanceUnit)\(age)",
                      systemImage: symbol)
                Label("\(s.batteryLevel)%\(age)", systemImage: symbol)
            }
        } else {
            Label("Volta", systemImage: "bolt.car")
        }
    }
}

#Preview("Circular", as: .accessoryCircular) {
    VoltaAccessoryWidget()
} timeline: {
    VoltaEntry(date: .now, snapshot: .fixture())
    VoltaEntry(date: .now, snapshot: .fixtureCharging())
    VoltaEntry(date: .now, snapshot: .fixtureLowStale())
    VoltaEntry(date: .now, snapshot: nil)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    VoltaAccessoryWidget()
} timeline: {
    VoltaEntry(date: .now, snapshot: .fixture())
    VoltaEntry(date: .now, snapshot: .fixtureCharging())
    VoltaEntry(date: .now, snapshot: .fixtureLowStale())
    VoltaEntry(date: .now, snapshot: nil)
}

#Preview("Inline", as: .accessoryInline) {
    VoltaAccessoryWidget()
} timeline: {
    VoltaEntry(date: .now, snapshot: .fixture())
    VoltaEntry(date: .now, snapshot: .fixtureCharging())
    VoltaEntry(date: .now, snapshot: .fixtureLowStale())
    VoltaEntry(date: .now, snapshot: nil)
}
