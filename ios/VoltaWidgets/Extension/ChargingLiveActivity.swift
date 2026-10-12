import ActivityKit
import SwiftUI
import WidgetKit

// Every presentation (Lock Screen, expanded, compact, minimal) honors
// `context.isStale` and the final phases (completed / stopped). The live
// countdown only runs while charging with fresh data; otherwise it is frozen
// as an end time or "—".

struct ChargingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargingActivityAttributes.self) { context in
            ChargingLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(WTheme.background.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "volta://charging"))
        } dynamicIsland: { context in
            let a = context.attributes, s = context.state
            let look = ChargeLook(attributes: a, state: s, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        ChargeVehicleLabel(look: look)
                        WNumber(value: "\(s.batteryLevel)", unit: "%", size: 30)
                            .opacity(look.dataOpacity)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        ChargeStateLabel(look: look)
                        ChargeReading(look: look, size: 22)
                            .opacity(look.dataOpacity)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ChargeSegmentBar(state: s, tint: look.tint, height: 9)
                        ChargeFooter(look: look)
                    }
                    .opacity(look.dataOpacity)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: look.symbol).foregroundStyle(look.tint)
                    Text("\(s.batteryLevel)%").fontWeight(.semibold).opacity(look.dataOpacity)
                }
                .font(.system(size: 14))
            } compactTrailing: {
                ChargeTrailingValue(look: look, size: 14, compact: true)
                    .frame(maxWidth: 52)
            } minimal: {
                ChargeRing(state: s, look: look)
            }
            .keylineTint(look.tint)
            .widgetURL(URL(string: "volta://charging"))
        }
    }
}

/// Text, symbols and tint for one charging state, shared by every presentation.
struct ChargeLook {
    var attributes: ChargingActivityAttributes
    var state: ChargingActivityAttributes.ContentState
    var isStale: Bool

    var phase: ChargingActivityAttributes.Phase { state.phase }
    /// The countdown runs only while charging on fresh data.
    var showsCountdown: Bool { phase == .charging && !isStale }
    var staleCharging: Bool { isStale && phase == .charging }

    /// "Charging", "Supercharging", "Complete", "Stopped" or "Stale".
    var stateTitle: String {
        if staleCharging { return "Stale" }
        switch phase {
        case .charging: return attributes.fastCharger == true ? "Supercharging" : "Charging"
        case .completed: return "Complete"
        case .stopped: return "Stopped"
        }
    }
    /// "AC" or "DC"; nil when the charger type is unknown.
    var current: String? { attributes.fastCharger.map { $0 ? "DC" : "AC" } }
    var symbol: String {
        if staleCharging { return "clock.badge.exclamationmark" }
        switch phase {
        case .charging: return "bolt.fill"
        case .completed: return "checkmark.circle.fill"
        case .stopped: return "bolt.slash.fill"
        }
    }
    var tint: Color {
        if staleCharging { return WTheme.amber }
        return phase == .stopped ? WTheme.label : WTheme.green
    }
    /// Stale numbers are dimmed so they read as "last known".
    var dataOpacity: Double { staleCharging ? 0.6 : 1 }
}

/// "⚡ FRIDAY · AC"
struct ChargeVehicleLabel: View {
    var look: ChargeLook
    var size: CGFloat = 12
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: look.symbol).foregroundStyle(look.tint)
            Text(look.attributes.vehicleName.uppercased()).foregroundStyle(.white).tracking(1.6)
            if let current = look.current {
                Text("· " + current).foregroundStyle(WTheme.label).tracking(1.2)
            }
        }
        .font(.system(size: size, weight: .semibold))
        .lineLimit(1)
    }
}

/// "● CHARGING" in the state's tint.
struct ChargeStateLabel: View {
    var look: ChargeLook
    var size: CGFloat = 12
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(look.tint).frame(width: 6, height: 6)
            Text(look.stateTitle.uppercased()).tracking(1.6)
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(look.tint)
        .lineLimit(1)
    }
}

/// Power while charging; the range once the session has ended.
struct ChargeReading: View {
    var look: ChargeLook
    var size: CGFloat
    var body: some View {
        let s = look.state
        if s.phase == .charging {
            WNumber(value: s.chargerPowerKw.map { $0.formatted(.number.precision(.fractionLength($0 >= 20 ? 0 : 1))) } ?? "—",
                    unit: "kW", size: size)
        } else {
            let u = WidgetUnits(miles: look.attributes.usesMiles)
            WNumber(value: u.distance(s.rangeKm), unit: u.distanceUnit, size: size)
        }
    }
}

/// "+17.1 kWh" on the left; "2:26 to 80%", "Updated 3:42 PM" or the end time on the right.
struct ChargeFooter: View {
    var look: ChargeLook
    var body: some View {
        HStack {
            Text(look.state.energyAddedKwh.map { "+" + WidgetFormat.energy($0) } ?? "")
                .foregroundStyle(WTheme.label)
            Spacer(minLength: 8)
            status
        }
        .font(.system(size: 14, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    @ViewBuilder private var status: some View {
        let s = look.state, limit = s.chargeLimit.map { " to \($0)%" } ?? ""
        if look.staleCharging {
            Text("Updated \(Text(s.updatedAt, style: .time))").foregroundStyle(WTheme.amber)
        } else if s.phase == .charging {
            if let fullAt = s.fullAt, fullAt > .now {
                // Bounded: stops at zero instead of counting up past the estimate.
                Text("\(Text(.currentDate, format: .timer(countingDownIn: Date.now..<fullAt, maxFieldCount: 2, maxPrecision: .seconds(60))))\(limit)")
                    .foregroundStyle(.white).monospacedDigit()
            } else {
                Text("Charging\(limit)").foregroundStyle(.white)
            }
        } else if let endedAt = s.endedAt {
            Text("\(s.phase == .completed ? "Finished" : "Ended") \(Text(endedAt, style: .time))")
                .foregroundStyle(.white)
        }
    }
}

/// Live countdown while charging; otherwise a frozen time or "—".
struct ChargeTrailingValue: View {
    var look: ChargeLook
    var size: CGFloat
    var compact = false
    var body: some View {
        Group {
            if look.showsCountdown {
                ChargeETA(fullAt: look.state.fullAt, size: size, compact: compact)
            } else if look.phase == .charging {
                // Stale: show when the data is from instead of a countdown that may be wrong.
                (compact ? Text("Stale") : Text(look.state.updatedAt, style: .time))
                    .foregroundStyle(WTheme.amber)
            } else if compact {
                Text(look.phase == .completed ? "Done" : "Stopped").foregroundStyle(look.tint)
            } else if let endedAt = look.state.endedAt {
                Text(endedAt, style: .time).foregroundStyle(.white)
            } else {
                Text("—").foregroundStyle(.white)
            }
        }
        .font(.system(size: size, weight: compact ? .semibold : .bold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// Live countdown to the charge limit.
struct ChargeETA: View {
    var fullAt: Date?
    var size: CGFloat
    var compact = false
    var body: some View {
        Group {
            if let fullAt, fullAt > .now {
                Text(timerInterval: Date.now...fullAt, countsDown: true, showsHours: true)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            } else {
                Text("—")
            }
        }
        .font(.system(size: size, weight: .bold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(compact ? 0.7 : 0.8)
    }
}

/// "Stale · updated 3:42 PM" in amber.
struct StaleNote: View {
    var updatedAt: Date
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.badge.exclamationmark")
            Text("Stale · updated \(Text(updatedAt, style: .time))")
        }
        .foregroundStyle(WTheme.amber)
    }
}

/// Battery as a row of separate cells: bright up to the level, dim up to the
/// charge limit, dark beyond it. The cell holding the level is half-lit.
struct ChargeSegmentBar: View {
    var state: ChargingActivityAttributes.ContentState
    var tint: Color = WTheme.green
    var segments = 30
    var height: CGFloat = 11

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: min(3, height / 3), style: .continuous)
                    .fill(color(i))
            }
        }
        .frame(height: height)
    }

    private func color(_ i: Int) -> Color {
        let start = Double(i) / Double(segments) * 100, end = Double(i + 1) / Double(segments) * 100
        let level = Double(state.batteryLevel)
        if level >= end { return tint }
        if level > start { return tint.opacity(0.5) }
        if let limit = state.chargeLimit, Double(limit) > start { return tint.opacity(0.2) }
        return WTheme.track
    }
}

struct ChargeRing: View {
    var state: ChargingActivityAttributes.ContentState
    var look: ChargeLook
    var body: some View {
        ZStack {
            Circle().stroke(WTheme.track, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: state.fractionOfLimit ?? Double(state.batteryLevel) / 100)
                .stroke(look.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: look.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(look.tint)
        }
        .padding(1)
    }
}

/// Wattly-style card: vehicle and state, level and power, the cell bar, then
/// energy added and time to the limit.
struct ChargingLockScreenView: View {
    var attributes: ChargingActivityAttributes
    var state: ChargingActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        let look = ChargeLook(attributes: attributes, state: state, isStale: isStale)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ChargeVehicleLabel(look: look, size: 13)
                Spacer(minLength: 8)
                ChargeStateLabel(look: look, size: 13)
            }
            HStack(alignment: .lastTextBaseline) {
                WNumber(value: "\(state.batteryLevel)", unit: "%", size: 46)
                Spacer()
                ChargeReading(look: look, size: 28)
            }
            .opacity(look.dataOpacity)
            VStack(spacing: 8) {
                ChargeSegmentBar(state: state, tint: look.tint)
                ChargeFooter(look: look)
            }
            .opacity(look.dataOpacity)
        }
        .padding(16)
    }
}

// MARK: - Previews

#Preview("Charging · Lock Screen", as: .content, using: ChargingActivityAttributes.fixture) {
    ChargingLiveActivity()
} contentStates: {
    ChargingActivityAttributes.ContentState.early
    ChargingActivityAttributes.ContentState.midway
    ChargingActivityAttributes.ContentState.unknownLimit
    ChargingActivityAttributes.ContentState.complete
    ChargingActivityAttributes.ContentState.stopped
}

#Preview("Supercharging · Lock Screen", as: .content, using: ChargingActivityAttributes.fixtureSupercharger) {
    ChargingLiveActivity()
} contentStates: {
    ChargingActivityAttributes.ContentState.supercharging
}

#Preview("Charging · Expanded", as: .dynamicIsland(.expanded), using: ChargingActivityAttributes.fixture) {
    ChargingLiveActivity()
} contentStates: {
    ChargingActivityAttributes.ContentState.midway
    ChargingActivityAttributes.ContentState.complete
    ChargingActivityAttributes.ContentState.stopped
}

#Preview("Charging · Compact", as: .dynamicIsland(.compact), using: ChargingActivityAttributes.fixture) {
    ChargingLiveActivity()
} contentStates: {
    ChargingActivityAttributes.ContentState.midway
    ChargingActivityAttributes.ContentState.complete
    ChargingActivityAttributes.ContentState.stopped
}

#Preview("Charging · Minimal", as: .dynamicIsland(.minimal), using: ChargingActivityAttributes.fixture) {
    ChargingLiveActivity()
} contentStates: {
    ChargingActivityAttributes.ContentState.midway
    ChargingActivityAttributes.ContentState.complete
}
