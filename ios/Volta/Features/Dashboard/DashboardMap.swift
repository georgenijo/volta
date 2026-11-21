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
    /// MapKit's setup takes main-thread time; at launch the map waits until
    /// the first frame, with the battery and status, is on screen.
    var launchFrame = LaunchFrame.shared

    var body: some View {
        if let location {
            ZStack {
                backdrop
                if launchFrame.isShown { map(for: location).transition(.opacity) }
            }
            .animation(.easeOut(duration: 0.25), value: launchFrame.isShown)
        } else {
            unavailable
        }
    }

    private var backdrop: some View {
        LinearGradient(colors: [.voltaMapBackdrop, .voltaBackground], startPoint: .top, endPoint: .bottom)
    }

    private func map(for location: Location) -> some View {
        BackdropMap(location: location) {
            ZStack {
                if charging {
                    ChargingMarker()
                } else {
                    CarMarker(heading: location.heading, tint: sentry ? .voltaRed : .voltaBlue)
                }
                AddressPill(location: location, sentry: sentry, state: state,
                            charging: charging, chargerPowerKw: chargerPowerKw)
                    // A map label: the map's own accessibility label reads the
                    // place at any size, so the pill keeps clear of the wordmark.
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
                    .alignmentGuide(VerticalAlignment.center) { d in d[.bottom] + 16 }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map: car at \(AddressPill.title(for: location))")
    }

    private var unavailable: some View {
        ZStack {
            backdrop
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

/// One map for the life of the dashboard. A new fix (every refresh and live
/// poll moves the car a little) glides the camera there instead of rebuilding
/// the map, which reloaded its tiles and snapped them in.
private struct BackdropMap<Overlay: View>: View {
    var location: Location
    @ViewBuilder var overlay: Overlay
    @State private var position: MapCameraPosition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(location: Location, @ViewBuilder overlay: () -> Overlay) {
        self.location = location
        self.overlay = overlay()
        _position = State(initialValue: .camera(Self.camera(for: location)))
    }

    static func camera(for location: Location) -> MapCamera {
        MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
                  distance: 800, heading: 0, pitch: 55)
    }

    var body: some View {
        // The camera centers the car, so the marker and pill are drawn as a
        // centered overlay (kept out of the map so they stay in color).
        Map(position: $position, interactionModes: [])
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted,
                                pointsOfInterest: .excludingAll, showsTraffic: false))
            .mapControlVisibility(.hidden)
            // Wattly's map is near-monochrome charcoal; the light map is its pale twin.
            .voltaBackdropMapTone()
            .overlay { overlay }
            .onChange(of: [location.latitude, location.longitude]) {
                let camera = Self.camera(for: location)
                if reduceMotion {
                    position = .camera(camera)
                } else {
                    withAnimation(.smooth(duration: 1.2)) { position = .camera(camera) }
                }
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
                .fill(Color.white)  // appearance: fixed (the marker's rim reads on light and dark maps)
                .frame(width: 24, height: 24)
                .shadow(color: Color.voltaShadow.opacity(0.5), radius: 4, y: 2)
            Circle()
                .fill(tint)
                .frame(width: 13, height: 13)
            Image(systemName: "shield.fill")
                .font(.system(size: 7, weight: .bold))
                // White on the light map's deeper red; main's black at 60% on the dark map's red.
                .foregroundStyle(Color(light: .white, dark: .black.opacity(0.6)))
                .opacity(tint == .voltaRed ? 1 : 0)
        }
        .frame(width: 92, height: 92)
    }
}

/// Charging pin: a green disc with a dark ring and bolt, and one ring
/// expanding from it every 2.4 s while charging (static under Reduce Motion).
/// The ring only runs while it can be seen: the scene is active and the
/// marker is on screen.
struct ChargingMarker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false
    /// The marker's disc: the same green on both maps by design, so the pin
    /// is one recognisable sign; its edge follows the route casing.
    private static let green = Color(hex: 0x5ECB93)  // appearance: fixed (map marker)

    var body: some View {
        ZStack {
            // One ring expanding from the disc while power flows (this marker
            // is shown only then); none of it under Reduce Motion.
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: nil, paused: scenePhase != .active || !onScreen)) { context in
                    let phase: Double = (context.date.timeIntervalSinceReferenceDate / 2.4).truncatingRemainder(dividingBy: 1)
                    let side: CGFloat = 30 * (1 + 0.9 * phase)
                    Circle()
                        .stroke(Self.green, lineWidth: 1.5)
                        .frame(width: side, height: side)
                        .opacity(0.5 * (1 - phase))
                }
            }
            Circle()
                .fill(Self.green)
                .frame(width: 30, height: 30)
                .overlay { Circle().strokeBorder(RoutePalette.casingColor, lineWidth: 2) }
            // The charge-state vocabulary's glyph.
            Image(systemName: StateDisplay.charging(.charging).symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: 0x06140D))  // appearance: fixed (a glyph on the green disc)
        }
        .frame(width: 92, height: 92)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        // Inside a scroll view: scrolled out of sight counts as off screen.
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
    }
}

/// "Home / PALO ALTO" pill with a hairline stem: where the car is, nothing
/// else. The Dashboard's Now card carries what the car is doing.
struct AddressPill: View {
    var location: Location
    // Kept for the map's call; the pill no longer shows state.
    var sentry: Bool
    var state: VehicleState?
    var charging: Bool = false
    var chargerPowerKw: Double? = nil

    static func title(for location: Location) -> String {
        if let place = location.placeName, !place.isEmpty { return place }
        return location.address?.split(separator: ",").first.map { String($0).trimmed } ?? "Unknown location"
    }

    /// The town: the address's first part under a place name, else its second.
    static func locality(for location: Location) -> String? {
        let parts = location.address?.split(separator: ",").map { String($0).trimmed } ?? []
        if location.placeName != nil { return parts.first }
        return parts.dropFirst().first
    }

    /// Frosted plate over the map: dark glass on the dark map, light glass on
    /// the light one.
    static let plate = Color(light: .white.opacity(0.85), dark: .black.opacity(0.72))

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(Self.title(for: location))
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(Color.voltaTextPrimary)
                    .lineLimit(1)
                if let locality = Self.locality(for: location) {
                    Text(locality)
                        .font(.system(.caption, weight: .semibold))
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.voltaTextSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, VoltaSpacing.lg + 2)
            .padding(.vertical, VoltaSpacing.md)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Self.plate)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.voltaInk.opacity(0.1), lineWidth: 1)
                    }
            }
            Rectangle()
                .fill(Color.voltaInk.opacity(0.35))
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
