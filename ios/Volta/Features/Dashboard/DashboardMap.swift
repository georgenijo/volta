import MapKit
import SwiftUI

/// Dark, pitched 3D map centered on the car, with a heading marker and an
/// address pill. Non-interactive: it's a backdrop for the dashboard.
struct DashboardMap: View {
    var location: Location?
    var sentry: Bool
    var state: VehicleState?

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
                    CarMarker(heading: location.heading, tint: sentry ? .voltaRed : .voltaBlue)
                    AddressPill(location: location, sentry: sentry, state: state)
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

/// "Street / ● SENTRY · TOWN" pill with a hairline stem.
struct AddressPill: View {
    var location: Location
    var sentry: Bool
    var state: VehicleState?

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
        sentry ? .voltaRed : (state?.color ?? .voltaTextSecondary)
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
                    if let locality {
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

#Preview("Map unavailable") {
    DashboardMap(location: nil, sentry: false, state: .asleep)
        .frame(height: 460)
}
