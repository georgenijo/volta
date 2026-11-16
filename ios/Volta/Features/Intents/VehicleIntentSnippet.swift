import SwiftUI

/// The card Siri and Shortcuts show under a read answer. It shows only what the
/// spoken answer says: unknown values read "Unknown", the age is always shown,
/// and location is a place name (no map, no coordinates).
struct VehicleIntentSnippet: View {
    enum Kind: Sendable { case battery, range, charging, location, security }

    let kind: Kind
    let readout: VehicleReadout
    let isDemo: Bool
    @Environment(\.colorScheme) private var scheme

    /// Secondary text. The system's `.secondary` falls to about 3.4:1 on the light
    /// snippet glass, so light uses `voltaTextSecondary`; dark keeps the system style.
    private var secondary: AnyShapeStyle {
        scheme == .dark ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.voltaTextSecondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.16), in: .circle)
                .accessibilityHidden(true)
            Text(readout.name).font(.headline).lineLimit(1)
            Spacer(minLength: 8)
            if isDemo {
                Text("Demo data")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.voltaBlue.opacity(0.18), in: .capsule)
                    .foregroundStyle(Color.voltaBlueText)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .battery:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    bigValue(readout.batteryPercent)
                    Text(readout.shortRange.map { "\($0) \(readout.rangeKind)" } ?? "Range unknown")
                        .font(.subheadline).foregroundStyle(secondary)
                }
                BatteryBar(level: readout.snapshot.batteryLevel, limit: readout.snapshot.chargeLimit, tint: tint)
            }
        case .range:
            VStack(alignment: .leading, spacing: 4) {
                bigValue(readout.shortRange ?? "Unknown", known: readout.shortRange != nil)
                Text("\(readout.rangeKind.capitalized) range · battery \(readout.batteryPercent)")
                    .font(.subheadline).foregroundStyle(secondary)
            }
        case .charging:
            VStack(alignment: .leading, spacing: 4) {
                bigValue(chargingTitle, known: readout.charging != .unknown)
                Text(chargingDetail).font(.subheadline).foregroundStyle(secondary)
            }
        case .location:
            VStack(alignment: .leading, spacing: 4) {
                bigValue(readout.locationTitle, known: readout.place != nil)
                    .lineLimit(2)
                if readout.snapshot.state == .driving {
                    Text("Driving · last known place").font(.subheadline).foregroundStyle(secondary)
                }
            }
        case .security:
            HStack(spacing: 12) {
                stateTile(title: "Doors", value: readout.lockText,
                          symbol: readout.snapshot.locked == false ? "lock.open.fill" : "lock.fill",
                          known: readout.snapshot.locked != nil)
                stateTile(title: "Sentry", value: readout.sentryText,
                          symbol: "shield.lefthalf.filled", known: readout.snapshot.sentryMode != nil)
            }
        }
    }

    private var footer: some View {
        // Location has its own timestamp; the overall age would overstate it.
        let stale = kind == .location ? readout.locationIsStale : readout.isStale
        return Label(Self.footerText(kind, readout: readout),
                     systemImage: stale ? "clock.badge.exclamationmark" : "clock")
            .font(.caption)
            .foregroundStyle(stale ? AnyShapeStyle(Color.voltaAmber) : secondary)
    }

    static func footerText(_ kind: Kind, readout: VehicleReadout) -> String {
        if kind == .location { return readout.locationFooter }
        return readout.isStale ? "From \(readout.age) · may be out of date" : "Updated \(readout.age)"
    }

    private func bigValue(_ text: String, known: Bool = true) -> some View {
        Text(text)
            .font(.system(size: 34, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(known ? AnyShapeStyle(.primary) : secondary)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }

    private func stateTile(title: String, value: String, symbol: String, known: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(secondary)
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(known ? AnyShapeStyle(.primary) : secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
    }

    private var chargingTitle: String {
        switch readout.charging {
        case .charging: "Charging"
        case .complete: "Complete"
        case .pluggedIn: "Plugged in"
        case .unplugged: "Unplugged"
        case .unknown: "Unknown"
        }
    }

    private var chargingDetail: String {
        var parts = [readout.batteryPercent]
        if readout.charging == .charging {
            parts.append(readout.shortTimeRemaining.map { "\($0) left" } ?? "time left unknown")
            if let limit = readout.snapshot.chargeLimit { parts.append("limit \(limit)%") }
        }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch kind {
        case .battery, .range: readout.batterySymbol
        case .charging: readout.charging == .charging ? "bolt.fill" : "bolt"
        case .location: readout.place == nil ? "mappin.slash" : "mappin.and.ellipse"
        case .security: readout.snapshot.locked == false ? "lock.open.fill" : "lock.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .charging: readout.charging == .charging ? .voltaGreen : .voltaBlue
        case .security: readout.snapshot.locked == false ? .voltaAmber : .voltaBlue
        case .battery: readout.charging == .charging ? .voltaGreen : readout.snapshot.batteryLevel <= 20 ? .voltaAmber : .voltaBlue
        default: .voltaBlue
        }
    }
}

/// Battery level with a tick at the charge limit (only when the limit is known).
private struct BatteryBar: View {
    let level: Int
    let limit: Int?
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: width * CGFloat(min(100, max(0, level))) / 100)
                if let limit {
                    Rectangle().fill(.primary.opacity(0.7))
                        .frame(width: 2, height: 14)
                        .offset(x: width * CGFloat(min(100, max(0, limit))) / 100 - 1)
                }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}
