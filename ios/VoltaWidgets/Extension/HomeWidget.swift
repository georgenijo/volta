import SwiftUI
import WidgetKit

/// Home Screen widget: small, medium and large.
struct VoltaHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotStore.homeWidgetKind, provider: VoltaProvider()) { entry in
            VoltaHomeWidgetView(entry: entry)
                .containerBackground(for: .widget) { WTheme.backgroundGradient }
                .widgetURL(URL(string: "volta://dashboard"))
        }
        .configurationDisplayName("Volta")
        .description("Battery, range and status for your car.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct VoltaHomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: VoltaEntry

    var body: some View {
        if let s = entry.snapshot {
            switch family {
            case .systemMedium: MediumWidgetView(s: s, now: entry.date)
            case .systemLarge: LargeWidgetView(s: s, now: entry.date)
            default: SmallWidgetView(s: s, now: entry.date)
            }
        } else {
            WidgetEmptyView()
        }
    }
}

// MARK: - Building blocks

struct WidgetEmptyView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.car")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(WTheme.label)
            Text("Open Volta").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            Text("Pair this iPhone to see your car here.")
                .font(.system(size: 11)).foregroundStyle(WTheme.label)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Vehicle name plus a state glyph, e.g. "FRIDAY   ⛨ Sentry".
struct WidgetHeader: View {
    var s: WidgetSnapshot
    var showStateText = true
    var body: some View {
        HStack(spacing: 6) {
            WLabel(s.vehicleName, color: .white.opacity(0.85))
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Image(systemName: WidgetFormat.stateSymbol(s))
                    .font(.system(size: 10, weight: .semibold))
                if showStateText { WLabel(WidgetFormat.stateText(s), color: stateColor) }
            }
            .foregroundStyle(stateColor)
        }
    }
    private var stateColor: Color {
        if s.isCharging || s.chargingState == .complete { return WTheme.green }
        switch s.state {
        case .driving: return WTheme.blue
        case .online: return s.sentryMode == true ? WTheme.red : WTheme.label
        default: return WTheme.label
        }
    }
}

struct BatteryBlock: View {
    var s: WidgetSnapshot
    var size: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WNumber(value: "\(s.batteryLevel)", unit: "%", size: size)
            WBar(fraction: Double(s.batteryLevel) / 100,
                 color: WTheme.batteryColor(s.batteryLevel, charging: s.isCharging),
                 marker: s.chargeLimit.map { Double($0) / 100 })
        }
    }
}

struct UpdatedLabel: View {
    var s: WidgetSnapshot
    var now: Date
    var body: some View {
        let stale = s.isStale(at: now)
        HStack(spacing: 3) {
            if stale { Image(systemName: "clock.badge.exclamationmark").font(.system(size: 9)) }
            Text("Updated " + WidgetFormat.relative(s.updatedAt, to: now))
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(stale ? WTheme.amber : WTheme.label.opacity(0.8))
        .lineLimit(1)
    }
}

struct StatusTile: View {
    var symbol: String
    var tint: Color
    var label: String
    var value: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                WLabel(label)
                Text(value).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WTheme.hairline))
    }
}

struct StatusGrid: View {
    var s: WidgetSnapshot
    var body: some View {
        let u = WidgetUnits(s)
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                StatusTile(symbol: s.locked == false ? "lock.open.fill" : "lock.fill",
                           tint: s.locked == false ? WTheme.amber : WTheme.red,
                           label: "Doors", value: s.locked.map { $0 ? "Locked" : "Unlocked" } ?? "—")
                StatusTile(symbol: "fanblades.fill", tint: s.climateOn == true ? WTheme.blue : WTheme.label,
                           label: "Climate", value: s.climateOn.map { $0 ? "On" : "Off" } ?? "—")
            }
            GridRow {
                StatusTile(symbol: "thermometer.medium", tint: WTheme.label, label: "Inside",
                           value: u.temperature(s.insideTempC))
                StatusTile(symbol: "cloud.sun.fill", tint: WTheme.label, label: "Outside",
                           value: u.temperature(s.outsideTempC))
            }
        }
    }
}

/// Compact status card for the medium widget: doors, climate, temperatures.
struct StatusList: View {
    var s: WidgetSnapshot
    var body: some View {
        let u = WidgetUnits(s)
        VStack(spacing: 0) {
            row(s.locked == false ? "lock.open.fill" : "lock.fill",
                s.locked == false ? WTheme.amber : WTheme.red,
                "Doors", s.locked.map { $0 ? "Locked" : "Unlocked" } ?? "—")
            Divider().overlay(WTheme.hairline)
            row("fanblades.fill", s.climateOn == true ? WTheme.blue : WTheme.label,
                "Climate", s.climateOn.map { $0 ? "On" : "Off" } ?? "—")
            Divider().overlay(WTheme.hairline)
            row("thermometer.medium", WTheme.label, "Inside", u.temperature(s.insideTempC))
            Divider().overlay(WTheme.hairline)
            row("cloud.sun.fill", WTheme.label, "Outside", u.temperature(s.outsideTempC))
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(WTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WTheme.hairline))
    }
    private func row(_ symbol: String, _ tint: Color, _ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            WLabel(label)
            Spacer(minLength: 4)
            Text(value).font(.system(size: 13, weight: .bold)).foregroundStyle(.white).lineLimit(1)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Charging detail line used when the car is plugged in.
struct ChargingLine: View {
    var s: WidgetSnapshot
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
            Text(WidgetFormat.power(s.chargerPowerKw))
            if let m = s.minutesToFull {
                Text("·").foregroundStyle(WTheme.label)
                // Unknown limit stays unknown rather than assuming 100%.
                Text("\(WidgetFormat.minutes(m)) to " + (s.chargeLimit.map { "\($0)%" } ?? "limit"))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(WTheme.green)
        .lineLimit(1).minimumScaleFactor(0.7)
    }
}

// MARK: - Families

struct SmallWidgetView: View {
    var s: WidgetSnapshot
    var now: Date
    var body: some View {
        let u = WidgetUnits(s)
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(s: s, showStateText: false)
            Spacer(minLength: 6)
            BatteryBlock(s: s, size: 46)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(u.distance(s.rangeKm)).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                Text(u.distanceUnit).font(.system(size: 11, weight: .medium)).foregroundStyle(WTheme.label)
                Spacer(minLength: 4)
            }
            Group {
                // Stale data says so instead of presenting old charging/state info as current.
                if s.isStale(at: now) { UpdatedLabel(s: s, now: now) }
                else if s.isCharging { ChargingLine(s: s) } else {
                    Text(WidgetFormat.stateText(s) + (s.placeName.map { " · \($0)" } ?? ""))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(WTheme.label).lineLimit(1)
                }
            }
            .padding(.top, 2)
        }
    }
}

struct MediumWidgetView: View {
    var s: WidgetSnapshot
    var now: Date
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeader(s: s, showStateText: false)
                Spacer(minLength: 4)
                BatteryBlock(s: s, size: 38)
                Spacer(minLength: 10)
                if s.isCharging { ChargingLine(s: s) } else {
                    let u = WidgetUnits(s)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(u.distance(s.rangeKm)).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                        Text("\(u.distanceUnit) range").font(.system(size: 11, weight: .medium)).foregroundStyle(WTheme.label)
                    }
                }
                Spacer(minLength: 4)
                UpdatedLabel(s: s, now: now)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StatusList(s: s)
                .frame(maxWidth: .infinity)
        }
    }
}

struct LargeWidgetView: View {
    var s: WidgetSnapshot
    var now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(s: s)
            HStack(alignment: .bottom) {
                WNumber(value: "\(s.batteryLevel)", unit: "%", size: 52)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    WLabel("Est. range")
                    let u = WidgetUnits(s)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(u.distance(s.rangeKm)).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                        Text(u.distanceUnit).font(.system(size: 12, weight: .medium)).foregroundStyle(WTheme.label)
                    }
                }
            }
            WBar(fraction: Double(s.batteryLevel) / 100,
                 color: WTheme.batteryColor(s.batteryLevel, charging: s.isCharging),
                 marker: s.chargeLimit.map { Double($0) / 100 })
            if s.isCharging { ChargingLine(s: s) }
            StatusGrid(s: s).frame(height: 96)
            TodayRow(s: s, now: now)
            TimelineStrip(segments: s.timeline, now: now)
            Spacer(minLength: 0)
            UpdatedLabel(s: s, now: now)
        }
    }
}

struct TodayRow: View {
    var s: WidgetSnapshot
    var now: Date
    var body: some View {
        let u = WidgetUnits(s)
        // Totals from an earlier day are unknown today, not yesterday's numbers.
        let t = s.todayTotals(at: now)
        VStack(alignment: .leading, spacing: 6) {
            WLabel("Today")
            HStack(spacing: 0) {
                stat(t.map { u.distanceWithUnit($0.distanceKm, digits: 1) } ?? "—", "Distance")
                stat(t.map { "\($0.driveCount)" } ?? "—", t?.driveCount == 1 ? "Drive" : "Drives")
                stat(WidgetFormat.energy(t?.energyUsedKwh), "Used")
                stat(WidgetFormat.energy(t?.energyAddedKwh), "Added")
            }
        }
    }
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(WTheme.label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The dashboard's "LAST 48H" strip: drives red, charging green, online blue.
struct TimelineStrip: View {
    var segments: [WidgetSnapshot.Segment]
    var now: Date
    var hours: Double = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                WLabel("Last 48h")
                Spacer()
                legend("Drives", WTheme.red)
                legend("Charging", WTheme.green)
                legend("Online", WTheme.blue)
            }
            GeometryReader { geo in
                let start = now.addingTimeInterval(-hours * 3600)
                let total = hours * 3600
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.05))
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        let x0 = max(0, seg.start.timeIntervalSince(start) / total)
                        let x1 = min(1, seg.end.timeIntervalSince(start) / total)
                        if x1 > x0, seg.kind != .asleep, seg.kind != .offline {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(WTheme.color(for: seg.kind))
                                .frame(width: max(2, (x1 - x0) * geo.size.width))
                                .offset(x: x0 * geo.size.width)
                        }
                    }
                }
            }
            .frame(height: 16)
            HStack {
                Text("48h ago"); Spacer(); Text("24h"); Spacer(); Text("Now")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(WTheme.label.opacity(0.8))
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(WTheme.label)
        }
        .padding(.leading, 6)
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    VoltaHomeWidget()
} timeline: {
    VoltaEntry(date: .now, snapshot: .fixture())
    VoltaEntry(date: .now, snapshot: .fixtureCharging())
    VoltaEntry(date: .now, snapshot: .fixtureDriving())
    VoltaEntry(date: .now, snapshot: .fixtureLowStale())
    VoltaEntry(date: .now, snapshot: .fixtureChargingStale())
    VoltaEntry(date: .now, snapshot: nil)
}

#Preview("Medium", as: .systemMedium) {
    VoltaHomeWidget()
} timeline: {
    VoltaEntry(date: .now, snapshot: .fixture())
    VoltaEntry(date: .now, snapshot: .fixtureCharging())
    VoltaEntry(date: .now, snapshot: .fixtureLowStale())
    VoltaEntry(date: .now, snapshot: nil)
}

#Preview("Large", as: .systemLarge) {
    VoltaHomeWidget()
} timeline: {
    VoltaEntry(date: .now, snapshot: .fixture())
    VoltaEntry(date: .now, snapshot: .fixtureCharging())
    VoltaEntry(date: .now, snapshot: .fixtureLowStale())
    VoltaEntry(date: .now, snapshot: nil)
}
