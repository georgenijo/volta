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

/// Sizes every map shares for its bottom edge.
enum VoltaMapChrome {
    /// The fade from the map into the page.
    static let fade: CGFloat = 40
    /// MapKit's logo and Legal link: about 8 pt above the fade's start, about
    /// 20 pt tall. Content kept clear of them adds this to the fade.
    static let attribution: CGFloat = 28
}

extension View {
    /// Darkens the tiles so labels recede, but never MapKit's logo and Legal
    /// link: the dim eases off to nothing across the 32 pt above the
    /// attribution row, which (with the fade below it) stays at full strength.
    /// `bottom` is the map's bottom padding (where the attribution sits).
    func voltaMapDim(_ opacity: Double, bottom: CGFloat, ignoring edges: Edge.Set = []) -> some View {
        overlay {
            GeometryReader { geo in
                let h = max(geo.size.height, 1)
                let clear = max(0, min(1, (h - bottom - VoltaMapChrome.attribution) / h))
                let full = max(0, clear - 32 / h)
                LinearGradient(stops: [.init(color: .black.opacity(opacity), location: 0),
                                       .init(color: .black.opacity(opacity), location: full),
                                       .init(color: .black.opacity(0), location: clear),
                                       .init(color: .black.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea(edges: edges)
            .allowsHitTesting(false)
        }
    }
}

extension MapCameraPosition {
    /// `.rect(rect)`, kept distinct from `current`. SwiftUI doesn't re-apply a
    /// position equal to the one it holds, so a map laid out twice whose two
    /// fits come out equal (a first pass without its top safe area, then the
    /// real one) would keep whatever camera MapKit chose on the resize. A
    /// shift of a thousandth of a map point (well under a millimetre) makes
    /// the value new without moving anything visibly.
    static func fitting(_ rect: MKMapRect, replacing current: MapCameraPosition) -> MapCameraPosition {
        guard let old = current.rect, old.origin.x == rect.origin.x, old.origin.y == rect.origin.y,
              old.size.width == rect.size.width, old.size.height == rect.size.height else { return .rect(rect) }
        return .rect(rect.offsetBy(dx: 0.001, dy: 0))
    }
}

/// Bounding rect of `points`, at least `minMeters` across each way so a single
/// place isn't shown at street level. Nil without points.
func voltaBounds(_ points: [MKMapPoint], minMeters: Double = 2_000) -> MKMapRect? {
    guard let first = points.first else { return nil }
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for p in points.dropFirst() {
        minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
    }
    let minSide = minMeters * MKMapPointsPerMeterAtLatitude(first.coordinate.latitude)
    let w = max(maxX - minX, minSide), h = max(maxY - minY, minSide)
    return MKMapRect(x: (minX + maxX - w) / 2, y: (minY + maxY - h) / 2, width: w, height: h)
}

/// A map on the shared basemap with pins drawn over it in colour. MapKit
/// annotations would be drained to grey with the tiles, so each pin is placed
/// by MapKit's own projection and follows the camera. The camera frames every
/// pin whole (badge and callout, as measured) at least `clearance` from the
/// map's edges, whenever the pins, their sizes or the map's size change.
struct PinnedMap<Item: Identifiable, Pin: View>: View {
    var items: [Item]
    var coordinate: (Item) -> CLLocationCoordinate2D
    /// MapKit's padding: where the logo and Legal link sit.
    var safe = EdgeInsets()
    /// Least distance from the map's edges to the outer edge of any pin.
    var clearance = EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)
    /// Darkens the tiles under the pins (not the attribution).
    var dim: Double = 0.2
    var interactive = true
    /// Which point of the pin sits on the coordinate.
    var pinAnchor: UnitPoint = .bottom
    @ViewBuilder var pin: (Item) -> Pin

    @State private var position: MapCameraPosition = .automatic
    /// Changes with the camera, so the pins follow it.
    @State private var camera: MKMapRect?
    @State private var size: CGSize = .zero
    @State private var pinSizes: [Item.ID: CGSize] = [:]

    private struct FrameKey: Equatable { var size: CGSize; var ids: [Item.ID]; var reach: EdgeInsets }

    /// How far the largest pin reaches past its coordinate on each side.
    private var reach: EdgeInsets {
        var r = EdgeInsets()
        for item in items {
            guard let s = pinSizes[item.id] else { continue }
            r.leading = max(r.leading, s.width * pinAnchor.x)
            r.trailing = max(r.trailing, s.width * (1 - pinAnchor.x))
            r.top = max(r.top, s.height * pinAnchor.y)
            r.bottom = max(r.bottom, s.height * (1 - pinAnchor.y))
        }
        return EdgeInsets(top: r.top.rounded(.up), leading: r.leading.rounded(.up),
                          bottom: r.bottom.rounded(.up), trailing: r.trailing.rounded(.up))
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position, interactionModes: interactive ? [.pan, .zoom] : [])
                .mapControls { }
                .voltaBasemap()
                .safeAreaPadding(safe)
                .onMapCameraChange(frequency: .continuous) { camera = $0.rect }
                .voltaMapDim(dim, bottom: safe.bottom)
                .overlay {
                    // MapKit's own projection, in global space, so the pins sit
                    // on their coordinates whatever safe areas the map and this
                    // layer each see.
                    GeometryReader { geo in
                        if camera != nil {
                            let origin = geo.frame(in: .global).origin
                            ForEach(items) { item in
                                if let p = proxy.convert(coordinate(item), to: .global) {
                                    let id = item.id
                                    pin(item)
                                        .fixedSize()
                                        .onGeometryChange(for: CGSize.self) { $0.size } action: { pinSizes[id] = $0 }
                                        .position(x: p.x - origin.x, y: p.y - origin.y)
                                        .modifier(AnchorShift(anchor: pinAnchor, size: pinSizes[id] ?? .zero))
                                }
                            }
                        }
                    }
                }
                .clipped()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        }
        .onChange(of: FrameKey(size: size, ids: items.map(\.id), reach: reach), initial: true) { frame() }
    }

    private func frame() {
        guard let content = voltaBounds(items.map { MKMapPoint(coordinate($0)) }) else { position = .automatic; return }
        guard size.width > 0, size.height > 0 else { return }
        let r = reach
        let insets = EdgeInsets(top: clearance.top + r.top, leading: clearance.leading + r.leading,
                                bottom: clearance.bottom + r.bottom, trailing: clearance.trailing + r.trailing)
        // The margins hold as given: pins never trade them for size.
        let rect = TripRoute.fitted(content, size: size, safe: safe, insets: insets, strict: true)
        position = .fitting(rect, replacing: position)
    }
}

/// Moves a pin positioned by its centre so `anchor` (a point of the pin, in
/// unit coordinates) lands on the position instead.
private struct AnchorShift: ViewModifier {
    var anchor: UnitPoint
    var size: CGSize
    func body(content: Content) -> some View {
        content.offset(x: (0.5 - anchor.x) * size.width, y: (0.5 - anchor.y) * size.height)
    }
}
