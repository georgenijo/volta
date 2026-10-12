import MapKit
import SwiftUI

/// Dark, pitched 3D map centered on the car, with a heading marker and an
/// address pill. Non-interactive: it's a backdrop for the dashboard.
struct DashboardMap: View {
    var location: Location?
    var sentry: Bool
    var state: VehicleState?
    /// Live charging power; non-nil switches the marker and pill to charging.
    var charging: Bool = false
    var chargerPowerKw: Double? = nil

    var body: some View {
        if let location {
            map(for: location)
        } else {
            unavailable
        }
    }

    private func map(for location: Location) -> some View {
        let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        let camera = MapCamera(centerCoordinate: coordinate, distance: 800, heading: 0, pitch: 55)
        // The camera centers the car, so the marker and pill are drawn as a
        // centered overlay (kept out of the map so they stay in color).
        return Map(initialPosition: .camera(camera), interactionModes: [])
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted,
                                pointsOfInterest: .excludingAll, showsTraffic: false))
            .mapControlVisibility(.hidden)
            .environment(\.colorScheme, .dark)
            // Wattly's map is near-monochrome charcoal.
            .saturation(0)
            .brightness(-0.04)
            .overlay {
                ZStack {
                    if charging {
                        ChargingMarker()
                    } else {
                        CarMarker(heading: location.heading, tint: sentry ? .voltaRed : .voltaBlue)
                    }
                    AddressPill(location: location, sentry: sentry, state: state,
                                charging: charging, chargerPowerKw: chargerPowerKw)
                        .alignmentGuide(VerticalAlignment.center) { d in d[.bottom] + 16 }
                }
            }
        .id("\(location.latitude),\(location.longitude)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map: car at \(AddressPill.title(for: location))")
    }

    private var unavailable: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1B1E23), .voltaBackground], startPoint: .top, endPoint: .bottom)
            VStack(spacing: VoltaSpacing.sm) {
                Image(systemName: "location.slash")
                    .font(.system(size: 28, weight: .light))
                Text("Location unavailable")
                    .font(.footnote)
            }
            .foregroundStyle(Color.voltaTextTertiary)
            .padding(.top, 40)
        }
    }
}

/// Glowing dot with a soft heading cone.
struct CarMarker: View {
    var heading: Double?
    var tint: Color

    var body: some View {
        ZStack {
            if let heading {
                Circle()
                    .trim(from: 0, to: 0.17)
                    .stroke(
                        RadialGradient(colors: [tint.opacity(0.45), tint.opacity(0)], center: .center,
                                       startRadius: 0, endRadius: 46),
                        lineWidth: 46
                    )
                    .frame(width: 46, height: 46)
                    // trim starts at 3 o'clock; center the wedge on north, then apply heading.
                    .rotationEffect(.degrees(-90 - 0.17 * 180 + heading))
            }
            Circle()
                .fill(tint.opacity(0.25))
                .frame(width: 34, height: 34)
                .blur(radius: 4)
            Circle()
                .fill(Color.white)
                .frame(width: 24, height: 24)
                .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
            Circle()
                .fill(tint)
                .frame(width: 13, height: 13)
            Image(systemName: "shield.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.black.opacity(0.6))
                .opacity(tint == .voltaRed ? 1 : 0)
        }
        .frame(width: 92, height: 92)
    }
}

/// Charging pin: a white disc with a green bolt, a breathing green glow and
/// sparks drifting up off it.
struct ChargingMarker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TimelineView(.animation(paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    for i in 0..<9 {
                        let seed = Double(i) * 1.618
                        let phase = (t / (2.4 + seed.truncatingRemainder(dividingBy: 1.1)) + seed).truncatingRemainder(dividingBy: 1)
                        let angle = seed * 2.4
                        let x = center.x + cos(angle) * (10 + 18 * phase)
                        let y = center.y - 8 - 34 * phase + sin(angle) * 6
                        let r = 1.6 * (1 - phase) + 0.6
                        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                                 with: .color(Color.voltaGreen.opacity(0.85 * (1 - phase))))
                    }
                }
            }
            Circle()
                .fill(Color.voltaGreen.opacity(0.35))
                .frame(width: 46, height: 46)
                .blur(radius: 8)
                .phaseAnimator(reduceMotion ? [1] : [0.7, 1.15]) { view, scale in
                    view.scaleEffect(scale)
                } animation: { _ in .easeInOut(duration: 1.4) }
            Circle()
                .fill(Color.white)
                .frame(width: 26, height: 26)
                .shadow(color: .voltaGreen.opacity(0.8), radius: 6)
            Image(systemName: "bolt.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.voltaGreen)
        }
        .frame(width: 92, height: 92)
    }
}

/// "Street / ● SENTRY · TOWN" pill with a hairline stem; while charging,
/// "● CHARGING · 7.7 kW  LIVE ›".
struct AddressPill: View {
    var location: Location
    var sentry: Bool
    var state: VehicleState?
    var charging: Bool = false
    var chargerPowerKw: Double? = nil

    static func title(for location: Location) -> String {
        if let place = location.placeName, !place.isEmpty { return place }
        return location.address?.split(separator: ",").first.map { String($0).trimmed } ?? "Unknown location"
    }

    private var locality: String? {
        let parts = location.address?.split(separator: ",").map { String($0).trimmed } ?? []
        if location.placeName != nil { return parts.first }
        return parts.dropFirst().first
    }

    private var statusText: String {
        if charging {
            return chargerPowerKw.map { "Charging · \(VoltaFormat.number($0, digits: $0 >= 20 ? 0 : 1)) kW" } ?? "Charging"
        }
        if sentry { return "Sentry" }
        switch state {
        case .driving: return "Driving"
        case .charging: return "Charging"
        case .asleep: return "Asleep"
        case .offline: return "Offline"
        default: return "Parked"
        }
    }

    private var statusColor: Color {
        charging ? .voltaGreen : sentry ? .voltaRed : (state?.color ?? .voltaTextSecondary)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(Self.title(for: location))
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(Color.voltaTextPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    StatusDot(color: statusColor, size: 6)
                    Text(statusText)
                        .foregroundStyle(statusColor)
                    if charging {
                        HStack(spacing: 2) {
                            Text("Live")
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(Color.voltaGreen)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.voltaGreen.opacity(0.16), in: .capsule)
                        .padding(.leading, 4)
                    } else if let locality {
                        Text("·").foregroundStyle(Color.voltaTextTertiary)
                        Text(locality).foregroundStyle(Color.voltaTextSecondary)
                    }
                }
                .font(.system(.caption2, weight: .semibold))
                .tracking(1.6)
                .textCase(.uppercase)
                .lineLimit(1)
            }
            .padding(.horizontal, VoltaSpacing.lg + 2)
            .padding(.vertical, VoltaSpacing.md)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.72))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    }
            }
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 1, height: 26)
        }
        .fixedSize()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}

#Preview("Map") {
    DashboardMap(location: Location(latitude: 37.4419, longitude: -122.1430, heading: 115,
                                    address: "Palo Alto, CA", placeName: "Home"),
                 sentry: true, state: .online)
        .frame(height: 460)
        .ignoresSafeArea()
}

#Preview("Map charging") {
    DashboardMap(location: Location(latitude: 37.4419, longitude: -122.1430, heading: 115,
                                    address: "Palo Alto, CA", placeName: "Home"),
                 sentry: true, state: .charging, charging: true, chargerPowerKw: 7.7)
        .frame(height: 460)
        .ignoresSafeArea()
}

#Preview("Map unavailable") {
    DashboardMap(location: nil, sentry: false, state: .asleep)
        .frame(height: 460)
}
