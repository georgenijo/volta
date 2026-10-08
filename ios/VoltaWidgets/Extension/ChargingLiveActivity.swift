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
                        WLabel(look.shortTitle, color: look.tint)
                        WNumber(value: "\(s.batteryLevel)", unit: "%", size: 30)
                            .opacity(look.dataOpacity)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        WLabel(look.trailingLabel)
                        ChargeTrailingValue(look: look, size: 22)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Group {
                        if look.isStale {
                            StaleNote(updatedAt: s.updatedAt)
                        } else {
                            Text(a.vehicleName + (a.placeName.map { " · \($0)" } ?? ""))
                                .foregroundStyle(WTheme.label)
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        ChargeProgressBar(state: s, tint: look.tint)
                        ChargeMetricsRow(attributes: a, state: s, isStale: look.isStale)
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

    var title: String {
        switch phase {
        case .charging: attributes.fastCharger == true ? "Supercharging" : "Charging"
        case .completed: "Charge complete"
        case .stopped: "Charging stopped"
        }
    }
    var shortTitle: String {
        switch phase {
        case .charging: attributes.fastCharger == true ? "Supercharging" : "Charging"
        case .completed: "Charged"
        case .stopped: "Stopped"
        }
    }
    var symbol: String {
        if isStale && phase == .charging { return "clock.badge.exclamationmark" }
        switch phase {
        case .charging: return "bolt.fill"
        case .completed: return "checkmark.circle.fill"
        case .stopped: return "bolt.slash.fill"
        }
    }
    var tint: Color {
        if isStale && phase == .charging { return WTheme.amber }
        return phase == .stopped ? WTheme.label : WTheme.green
    }
    /// Stale numbers are dimmed so they read as "last known".
    var dataOpacity: Double { isStale && phase == .charging ? 0.6 : 1 }
    var trailingLabel: String {
        switch phase {
        case .charging: isStale ? "Updated" : "To " + WidgetFormat.percent(state.chargeLimit)
        case .completed: "Finished"
        case .stopped: "Ended"
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

/// Battery bar with the charge-limit tick (no tick when the limit is unknown).
struct ChargeProgressBar: View {
    var state: ChargingActivityAttributes.ContentState
    var tint: Color = WTheme.green
    var body: some View {
        WBar(fraction: Double(state.batteryLevel) / 100, color: tint,
             marker: state.chargeLimit.map { Double($0) / 100 }, height: 6)
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

struct ChargeMetricsRow: View {
    var attributes: ChargingActivityAttributes
    var state: ChargingActivityAttributes.ContentState
    var isStale = false
    var body: some View {
        let u = WidgetUnits(miles: attributes.usesMiles)
        HStack(spacing: 0) {
            // Power is a live reading: unknown once the session ended or the data is stale.
            metric(state.phase == .charging && !isStale ? WidgetFormat.power(state.chargerPowerKw) : "—", "Power")
            metric(state.energyAddedKwh.map { "+" + WidgetFormat.energy($0) } ?? "—", "Added")
            metric(u.distanceWithUnit(state.rangeKm), "Range")
        }
    }
    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
            WLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChargingLockScreenView: View {
    var attributes: ChargingActivityAttributes
    var state: ChargingActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        let look = ChargeLook(attributes: attributes, state: state, isStale: isStale)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: look.symbol).foregroundStyle(look.tint)
                WLabel(look.title, color: look.tint)
                WLabel("· " + attributes.vehicleName, color: .white.opacity(0.8))
                Spacer()
                if isStale && state.phase == .charging {
                    WLabel("Stale", color: WTheme.amber)
                } else if let place = attributes.placeName {
                    Text(place).font(.system(size: 11, weight: .medium)).foregroundStyle(WTheme.label).lineLimit(1)
                }
            }
            HStack(alignment: .lastTextBaseline) {
                WNumber(value: "\(state.batteryLevel)", unit: "%", size: 44)
                Text("of " + WidgetFormat.percent(state.chargeLimit))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(WTheme.label)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    ChargeTrailingValue(look: look, size: 24)
                    WLabel(lockScreenCaption(look))
                }
            }
            .opacity(look.dataOpacity)
            ChargeProgressBar(state: state, tint: look.tint).opacity(look.dataOpacity)
            ChargeMetricsRow(attributes: attributes, state: state, isStale: isStale).opacity(look.dataOpacity)
        }
        .padding(16)
    }

    private func lockScreenCaption(_ look: ChargeLook) -> String {
        switch look.phase {
        case .charging: look.isStale ? "Last update" : "To limit"
        case .completed: "Finished"
        case .stopped: "Stopped"
        }
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
