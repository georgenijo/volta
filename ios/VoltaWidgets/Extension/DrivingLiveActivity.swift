import ActivityKit
import SwiftUI
import WidgetKit

// Every presentation honors `context.isStale` and the final `.ended` phase.
// The elapsed timer only ticks while driving on fresh data; otherwise it is
// frozen at the end (or last update) time.

struct DrivingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DrivingActivityAttributes.self) { context in
            DrivingLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(WTheme.background.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "volta://drives"))
        } dynamicIsland: { context in
            let a = context.attributes, s = context.state
            let look = DriveLook(state: s, isStale: context.isStale)
            let u = WidgetUnits(miles: a.usesMiles)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        WLabel(look.title, color: look.tint)
                        WNumber(value: u.distance(s.distanceKm), unit: u.distanceUnit, size: 28)
                            .opacity(look.dataOpacity)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        WLabel("Battery")
                        WNumber(value: "\(s.batteryLevel)", unit: "%", size: 28)
                            .opacity(look.dataOpacity)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    if look.isStale {
                        StaleNote(updatedAt: s.updatedAt)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DrivingMetricsRow(attributes: a, state: s, isStale: look.isStale)
                        .opacity(look.dataOpacity)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: look.symbol).foregroundStyle(look.tint)
                    Text("\(s.batteryLevel)%").fontWeight(.semibold).opacity(look.dataOpacity)
                }
                .font(.system(size: 14))
            } compactTrailing: {
                Group {
                    if s.phase == .ended {
                        Text("Ended").foregroundStyle(WTheme.label)
                    } else if look.isStale {
                        Text("Stale").foregroundStyle(WTheme.amber)
                    } else {
                        Text(s.distanceKm == nil ? "—" : "\(u.distance(s.distanceKm)) \(u.distanceUnit)")
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
            } minimal: {
                Image(systemName: look.symbol).foregroundStyle(look.tint)
            }
            .keylineTint(look.tint)
            .widgetURL(URL(string: "volta://drives"))
        }
    }
}

struct DriveLook {
    var state: DrivingActivityAttributes.ContentState
    var isStale: Bool
    var title: String { state.phase == .ended ? "Drive ended" : "Driving" }
    var symbol: String {
        if state.phase == .ended { return "flag.checkered" }
        return isStale ? "clock.badge.exclamationmark" : "steeringwheel"
    }
    var tint: Color {
        if state.phase == .ended { return WTheme.label }
        return isStale ? WTheme.amber : WTheme.blue
    }
    var dataOpacity: Double { isStale && state.phase == .driving ? 0.6 : 1 }
}

/// Elapsed drive time: ticking while live, frozen otherwise, "—" without a start time.
struct DriveElapsed: View {
    var startedAt: Date?
    var state: DrivingActivityAttributes.ContentState
    var isStale: Bool
    var body: some View {
        if let startedAt {
            if state.phase == .driving && !isStale {
                Text(startedAt, style: .timer)
            } else {
                let end = state.endedAt ?? state.updatedAt
                Text(WidgetFormat.duration(end.timeIntervalSince(startedAt)))
            }
        } else {
            Text("—")
        }
    }
}

struct DrivingMetricsRow: View {
    var attributes: DrivingActivityAttributes
    var state: DrivingActivityAttributes.ContentState
    var isStale = false
    var body: some View {
        let u = WidgetUnits(miles: attributes.usesMiles)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                DriveElapsed(startedAt: attributes.startedAt, state: state, isStale: isStale)
                    .font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                    .lineLimit(1)
                WLabel(state.phase == .ended ? "Duration" : "Elapsed")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            metric(u.distanceWithUnit(state.rangeKm), "Range")
            metric(WidgetFormat.energy(state.energyUsedKwh), "Used")
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

struct DrivingLockScreenView: View {
    var attributes: DrivingActivityAttributes
    var state: DrivingActivityAttributes.ContentState
    var isStale = false
    var body: some View {
        let u = WidgetUnits(miles: attributes.usesMiles)
        let look = DriveLook(state: state, isStale: isStale)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: look.symbol).foregroundStyle(look.tint)
                WLabel(look.title, color: look.tint)
                WLabel("· " + attributes.vehicleName, color: .white.opacity(0.8))
                Spacer()
                if isStale && state.phase == .driving {
                    WLabel("Stale", color: WTheme.amber)
                } else if state.phase == .ended, let endedAt = state.endedAt {
                    Text("Ended \(Text(endedAt, style: .time))")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(WTheme.label).lineLimit(1)
                } else if let from = attributes.startAddress {
                    Text("from \(from)").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WTheme.label).lineLimit(1)
                }
            }
            Group {
                HStack(alignment: .lastTextBaseline) {
                    WNumber(value: u.distance(state.distanceKm), unit: u.distanceUnit, size: 40)
                    Spacer()
                    WNumber(value: "\(state.batteryLevel)", unit: "%", size: 40)
                }
                WBar(fraction: Double(state.batteryLevel) / 100,
                     color: WTheme.batteryColor(state.batteryLevel, charging: false), height: 6)
                DrivingMetricsRow(attributes: attributes, state: state, isStale: isStale)
            }
            .opacity(look.dataOpacity)
            if isStale && state.phase == .driving {
                StaleNote(updatedAt: state.updatedAt).font(.system(size: 11, weight: .medium))
            }
        }
        .padding(16)
    }
}

#Preview("Driving · Lock Screen", as: .content, using: DrivingActivityAttributes.fixture) {
    DrivingLiveActivity()
} contentStates: {
    DrivingActivityAttributes.ContentState.city
    DrivingActivityAttributes.ContentState.cruising
    DrivingActivityAttributes.ContentState.unknownDistance
    DrivingActivityAttributes.ContentState.ended
}

#Preview("Driving · Expanded", as: .dynamicIsland(.expanded), using: DrivingActivityAttributes.fixture) {
    DrivingLiveActivity()
} contentStates: {
    DrivingActivityAttributes.ContentState.cruising
    DrivingActivityAttributes.ContentState.ended
}

#Preview("Driving · Compact", as: .dynamicIsland(.compact), using: DrivingActivityAttributes.fixture) {
    DrivingLiveActivity()
} contentStates: {
    DrivingActivityAttributes.ContentState.cruising
    DrivingActivityAttributes.ContentState.ended
}

#Preview("Driving · Minimal", as: .dynamicIsland(.minimal), using: DrivingActivityAttributes.fixture) {
    DrivingLiveActivity()
} contentStates: {
    DrivingActivityAttributes.ContentState.cruising
}
