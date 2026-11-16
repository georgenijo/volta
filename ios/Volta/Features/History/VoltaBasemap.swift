import MapKit
import SwiftUI

extension MapStyle {
    /// The one basemap style: MapKit's standard map, muted, flat, with no
    /// points of interest or traffic.
    static var voltaMuted: MapStyle {
        .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false)
    }
}

extension View {
    /// The one basemap every Volta map uses, so none can drift: the muted
    /// style, dark, drained to grey. Routes and pins are drawn over the map,
    /// not in it, so they keep their colour (see `PinnedMap`).
    func voltaBasemap() -> some View {
        mapStyle(.voltaMuted)
            .environment(\.colorScheme, .dark)
            .saturation(0)
    }
}

/// An interactive map on the shared basemap with pins drawn over it in
/// colour. MapKit annotations would be drained to grey with the tiles, so
/// each pin is positioned from the map's projection and follows the camera.
/// The camera frames every pin when the pins change.
struct PinnedMap<Item: Identifiable, Pin: View>: View {
    var items: [Item]
    var coordinate: (Item) -> CLLocationCoordinate2D
    /// MapKit's padding: the area pins are framed into, and where the logo sits.
    var safe = EdgeInsets()
    /// Darkens the tiles under the pins.
    var dim: Double = 0.2
    /// Drawn with its bottom centre on the item's coordinate.
    @ViewBuilder var pin: (Item) -> Pin

    @State private var position: MapCameraPosition = .automatic
    /// Changes with the camera, so the pins follow it.
    @State private var camera: MKMapRect?

    var body: some View {
        MapReader { proxy in
            Map(position: $position)
                .mapControls { }
                .voltaBasemap()
                .safeAreaPadding(safe)
                .onMapCameraChange(frequency: .continuous) { camera = $0.rect }
                .overlay { Color.black.opacity(dim).ignoresSafeArea().allowsHitTesting(false) }
                .overlay {
                    // MapKit's own projection, in global space, so the pins sit
                    // on their coordinates whatever safe areas the map and this
                    // layer each see.
                    GeometryReader { geo in
                        if camera != nil {
                            let origin = geo.frame(in: .global).origin
                            ForEach(items) { item in
                                if let p = proxy.convert(coordinate(item), to: .global) {
                                    pin(item)
                                        .fixedSize()
                                        .frame(width: 1, height: 1, alignment: .bottom)
                                        .position(x: p.x - origin.x, y: p.y - origin.y)
                                }
                            }
                        }
                    }
                }
                .clipped()
        }
        .onChange(of: items.map(\.id), initial: true) { frame() }
    }

    /// Every pin, at least about 2 km across so one place isn't shown at street level.
    private func frame() {
        let points = items.map { MKMapPoint(coordinate($0)) }
        guard let first = points.first else { position = .automatic; return }
        var rect = MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))
        for p in points.dropFirst() { rect = rect.union(MKMapRect(origin: p, size: MKMapSize(width: 0, height: 0))) }
        let minSide = 2_000 * MKMapPointsPerMeterAtLatitude(coordinate(items[0]).latitude)
        rect = rect.insetBy(dx: -max(0, minSide - rect.width) / 2, dy: -max(0, minSide - rect.height) / 2)
        position = .rect(rect)
    }
}
