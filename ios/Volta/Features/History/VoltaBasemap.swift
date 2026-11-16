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

/// The area MapKit fits a camera rect into, as insets from the map's edges.
/// A map inherits safe areas (bars, a side strip) that MapKit adds to its own
/// padding, so the padding we give isn't the whole story: where the camera's
/// visible rect lands on screen is. Framing uses this, so the margins hold
/// whatever the map inherits.
enum MapFitArea {
    /// The visible rect's corners in `space` (a coordinate space declared on
    /// the map's `MapReader`, which moves with it). Nil until MapKit has
    /// placed the map: the first conversions can be hundreds of points off,
    /// so only an area inside the map counts.
    static func measure(_ proxy: MapProxy, visible: MKMapRect, size: CGSize, in space: String) -> EdgeInsets? {
        guard size.width > 0, size.height > 0,
              let a = proxy.convert(MKMapPoint(x: visible.minX, y: visible.minY).coordinate, to: .named(space)),
              let b = proxy.convert(MKMapPoint(x: visible.maxX, y: visible.maxY).coordinate, to: .named(space)) else { return nil }
        func r(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
        let measured = EdgeInsets(top: r(a.y), leading: r(a.x), bottom: r(size.height - b.y), trailing: r(size.width - b.x))
        let edges = [measured.top, measured.leading, measured.bottom, measured.trailing]
        guard edges.allSatisfy({ $0.isFinite && $0 >= -0.5 }),
              measured.top + measured.bottom < size.height - 1,
              measured.leading + measured.trailing < size.width - 1 else { return nil }
        return measured
    }

    /// `new` when it moves any edge by a point or more, else `old` (so a
    /// sub-point wobble doesn't refit the camera).
    static func settle(_ old: EdgeInsets?, _ new: EdgeInsets?) -> EdgeInsets? {
        guard let new else { return old }
        guard let old else { return new }
        let moved = abs(old.top - new.top) >= 1 || abs(old.leading - new.leading) >= 1
            || abs(old.bottom - new.bottom) >= 1 || abs(old.trailing - new.trailing) >= 1
        return moved ? new : old
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
    /// The area MapKit really fits into (see `MapFitArea`); `safe` until measured.
    @State private var fitArea: EdgeInsets?
    private static var space: String { "volta.pinned.map" }

    private struct FrameKey: Equatable { var size: CGSize; var ids: [Item.ID]; var reach: EdgeInsets; var area: EdgeInsets? }

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
                .onMapCameraChange(frequency: .continuous) { context in
                    camera = context.rect
                    measure(proxy)
                }
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
                // Once the map has settled, measure again: the first camera
                // reports can come before MapKit has placed it.
                .task(id: size) {
                    try? await Task.sleep(for: .milliseconds(350))
                    measure(proxy)
                }
        }
        .coordinateSpace(.named(Self.space))
        .onChange(of: FrameKey(size: size, ids: items.map(\.id), reach: reach, area: fitArea), initial: true) { frame() }
    }

    private func measure(_ proxy: MapProxy) {
        guard let camera else { return }
        let area = MapFitArea.settle(fitArea, MapFitArea.measure(proxy, visible: camera, size: size, in: Self.space))
        if area != fitArea { fitArea = area }
    }

    private func frame() {
        guard let content = voltaBounds(items.map { MKMapPoint(coordinate($0)) }) else { position = .automatic; return }
        guard size.width > 0, size.height > 0 else { return }
        let r = reach
        let insets = EdgeInsets(top: clearance.top + r.top, leading: clearance.leading + r.leading,
                                bottom: clearance.bottom + r.bottom, trailing: clearance.trailing + r.trailing)
        // The margins hold as given: pins never trade them for size.
        let rect = TripRoute.fitted(content, size: size, safe: fitArea ?? safe, insets: insets, strict: true)
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
