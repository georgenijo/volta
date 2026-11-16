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
    /// Least distance from a side bar's edge (iPhone Duo's tab strip) to
    /// anything fitted in a map that runs under it.
    static let barClearance: CGFloat = 32
}

extension EdgeInsets {
    /// These margins, with each side that has a bar (`bars`, from the
    /// window's safe area, as the system reports the strip) kept
    /// `VoltaMapChrome.barClearance` inside the bar's edge. For maps that run
    /// under the bars; a map inside the safe area already fits clear of them.
    func clearing(bars: EdgeInsets) -> EdgeInsets {
        var e = self
        if bars.leading > 0 { e.leading = max(e.leading, bars.leading + VoltaMapChrome.barClearance) }
        if bars.trailing > 0 { e.trailing = max(e.trailing, bars.trailing + VoltaMapChrome.barClearance) }
        return e
    }
}

extension View {
    /// Darkens the tiles so labels recede, but never MapKit's logo and Legal
    /// link: the dim eases off to nothing across the 32 pt above the
    /// attribution row, which (with the fade below it) stays at full strength.
    /// `bottom` is the map's bottom padding (where the attribution sits).
    /// Without `attribution` (a backdrop, whose logo and link stay at the
    /// bottom edge under the fade, as they always have) the dim is even.
    func voltaMapDim(_ opacity: Double, bottom: CGFloat, ignoring edges: Edge.Set = [], attribution: Bool = true) -> some View {
        overlay {
            GeometryReader { geo in
                let h = max(geo.size.height, 1)
                let clear = max(0, min(1, (h - bottom - VoltaMapChrome.attribution) / h))
                let full = max(0, clear - 32 / h)
                if attribution {
                    LinearGradient(stops: [.init(color: .black.opacity(opacity), location: 0),
                                           .init(color: .black.opacity(opacity), location: full),
                                           .init(color: .black.opacity(0), location: clear),
                                           .init(color: .black.opacity(0), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                } else {
                    Color.black.opacity(opacity)
                }
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
/// map's edges, whenever the pins, their places, their sizes or the map's
/// size change.
///
/// A pin can carry a callout, drawn above its badge, or below it, or not at
/// all when it would crowd another (see `CalloutLayout`); the badge stays.
struct PinnedMap<Item: Identifiable, Pin: View, Callout: View>: View {
    var items: [Item]
    var coordinate: (Item) -> CLLocationCoordinate2D
    /// MapKit's padding: where the logo and Legal link sit.
    var safe = EdgeInsets()
    /// Least distance from the map's edges to the outer edge of any pin.
    var clearance = EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)
    /// Darkens the tiles under the pins (not the attribution).
    var dim: Double = 0.2
    /// False for a backdrop: no padding, so MapKit's logo and Legal link
    /// stay at the bottom edge, and an even dim (see `backdrop()`).
    var attribution = true
    var interactive = true
    /// Which point of the pin sits on the coordinate.
    var pinAnchor: UnitPoint = .bottom
    /// Callouts are placed in this order, highest first (ties by ID).
    var rank: (Item) -> Int = { _ in 0 }
    var pin: (Item) -> Pin
    var callout: ((Item) -> Callout)?

    @State private var position: MapCameraPosition = .automatic
    /// Changes with the camera, so the pins follow it.
    @State private var camera: MKMapRect?
    @State private var size: CGSize = .zero
    @State private var pinSizes: [Item.ID: CGSize] = [:]
    @State private var calloutSizes: [Item.ID: CGSize] = [:]
    /// The area MapKit really fits into (see `MapFitArea`); `safe` until measured.
    @State private var fitArea: EdgeInsets?
    private static var space: String { "volta.pinned.map" }

    private var frameKey: PinnedMapFrame {
        PinnedMapFrame(size: size, ids: items.map { AnyHashable($0.id) }, coordinates: items.map(coordinate),
                       reach: reach, area: fitArea)
    }

    /// How far the largest pin reaches past its coordinate on each side. A
    /// callout may sit above or below its badge, so both sides keep room for it.
    private var reach: EdgeInsets {
        var r = EdgeInsets()
        for item in items {
            guard let s = pinSizes[item.id] else { continue }
            let c = callout == nil ? .zero : calloutSizes[item.id] ?? .zero
            let extra: CGFloat = c.height > 0 ? CalloutLayout.gap + c.height : 0
            r.leading = max(r.leading, s.width * pinAnchor.x, c.width / 2)
            r.trailing = max(r.trailing, s.width * (1 - pinAnchor.x), c.width / 2)
            r.top = max(r.top, s.height * pinAnchor.y + extra)
            r.bottom = max(r.bottom, s.height * (1 - pinAnchor.y) + extra)
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
                .voltaMapDim(dim, bottom: safe.bottom, attribution: attribution)
                .overlay {
                    // MapKit's own projection, in global space, so the pins sit
                    // on their coordinates whatever safe areas the map and this
                    // layer each see.
                    GeometryReader { geo in
                        if camera != nil {
                            pins(proxy, origin: geo.frame(in: .global).origin)
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
        .onChange(of: frameKey, initial: true) { frame() }
    }

    @ViewBuilder private func pins(_ proxy: MapProxy, origin: CGPoint) -> some View {
        let placed: [Projected] = items.compactMap { item in
            proxy.convert(coordinate(item), to: .global).map { Projected(item: item, point: CGPoint(x: $0.x - origin.x, y: $0.y - origin.y)) }
        }
        let badges: [Item.ID: CGRect] = Dictionary(placed.map { pin in
            let s = pinSizes[pin.id] ?? .zero
            return (pin.id, CGRect(x: pin.point.x - s.width * pinAnchor.x, y: pin.point.y - s.height * pinAnchor.y,
                                   width: s.width, height: s.height))
        }, uniquingKeysWith: { a, _ in a })
        let placements: [Item.ID: CalloutPlacement] = callout == nil ? [:] : CalloutLayout.place(placed.map { pin in
            CalloutLayout.Entry(id: pin.id, rank: rank(pin.item), badge: badges[pin.id] ?? .zero, callout: calloutSizes[pin.id] ?? .zero)
        })
        ForEach(placed) { projected in
            let item = projected.item, p = projected.point
            let id = item.id
            if let callout, let badge = badges[id] {
                let c = calloutSizes[id] ?? .zero
                let where_ = placements[id] ?? .above
                callout(item)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { calloutSizes[id] = $0 }
                    .position(x: badge.midX, y: where_ == .below ? badge.maxY + CalloutLayout.gap + c.height / 2
                                                                  : badge.minY - CalloutLayout.gap - c.height / 2)
                    // Crowded out: not shown, still measured.
                    .opacity(where_ == .hidden ? 0 : 1)
                    .allowsHitTesting(where_ != .hidden)
                    .accessibilityHidden(true)
            }
            pin(item)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { pinSizes[id] = $0 }
                .position(x: p.x, y: p.y)
                .modifier(AnchorShift(anchor: pinAnchor, size: pinSizes[id] ?? .zero))
        }
    }

    private struct Projected: Identifiable {
        var item: Item
        var point: CGPoint
        var id: Item.ID { item.id }
    }

    private func measure(_ proxy: MapProxy) {
        guard let camera else { return }
        let area = MapFitArea.settle(fitArea, MapFitArea.measure(proxy, visible: camera, size: size, in: Self.space))
        if area != fitArea { fitArea = area }
    }

    private func frame() {
        guard !items.isEmpty else { position = .automatic; return }
        guard let rect = frameKey.camera(safe: fitArea ?? safe, clearance: clearance) else { return }
        position = .fitting(rect, replacing: position)
    }
}

extension PinnedMap {
    /// A backdrop under page content: MapKit's logo and Legal link stay at
    /// the map's bottom edge, under the fade, as on the heroes they always
    /// have; the dim is even. Pass no `safe` padding. Framing is unchanged.
    func backdrop() -> Self {
        var map = self
        map.attribution = false
        return map
    }

    /// Pins with callouts (see `CalloutLayout`). The pin should carry the
    /// callout's text in its accessibility label: a callout can be hidden.
    init(items: [Item], coordinate: @escaping (Item) -> CLLocationCoordinate2D, safe: EdgeInsets = EdgeInsets(),
         clearance: EdgeInsets = EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24), dim: Double = 0.2,
         interactive: Bool = true, pinAnchor: UnitPoint = .bottom, rank: @escaping (Item) -> Int,
         @ViewBuilder pin: @escaping (Item) -> Pin, @ViewBuilder callout: @escaping (Item) -> Callout) {
        self.items = items; self.coordinate = coordinate; self.safe = safe; self.clearance = clearance
        self.dim = dim; self.interactive = interactive; self.pinAnchor = pinAnchor; self.rank = rank
        self.pin = pin; self.callout = callout
    }
}

extension PinnedMap where Callout == EmptyView {
    /// Pins only.
    init(items: [Item], coordinate: @escaping (Item) -> CLLocationCoordinate2D, safe: EdgeInsets = EdgeInsets(),
         clearance: EdgeInsets = EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24), dim: Double = 0.2,
         interactive: Bool = true, pinAnchor: UnitPoint = .bottom, @ViewBuilder pin: @escaping (Item) -> Pin) {
        self.items = items; self.coordinate = coordinate; self.safe = safe; self.clearance = clearance
        self.dim = dim; self.interactive = interactive; self.pinAnchor = pinAnchor
        self.pin = pin; self.callout = nil
    }
}

enum CalloutPlacement: Equatable { case above, below, hidden }

/// Where each pin's callout goes, from the projected bounds alone. Callouts
/// are placed one by one, highest `rank` first (ties by ID, so the result
/// never depends on input order). A callout goes above its badge unless it
/// would come within `margin` of a callout already placed or of any other
/// badge; then below, on the same test; else it is not shown and the badge
/// stands alone.
enum CalloutLayout {
    /// Space between a badge and its callout.
    static let gap: CGFloat = 4
    static let margin: CGFloat = 8

    struct Entry<ID: Hashable> {
        var id: ID
        var rank: Int
        var badge: CGRect
        var callout: CGSize
    }

    static func place<ID: Hashable>(_ entries: [Entry<ID>], margin: CGFloat = margin) -> [ID: CalloutPlacement] {
        let order = entries.sorted { a, b in
            a.rank != b.rank ? a.rank > b.rank : String(describing: a.id) < String(describing: b.id)
        }
        var placed: [CGRect] = []
        var result: [ID: CalloutPlacement] = [:]
        for e in order {
            func rect(_ placement: CalloutPlacement) -> CGRect {
                let y = placement == .below ? e.badge.maxY + gap : e.badge.minY - gap - e.callout.height
                return CGRect(x: e.badge.midX - e.callout.width / 2, y: y, width: e.callout.width, height: e.callout.height)
            }
            func clear(_ r: CGRect) -> Bool {
                let zone = r.insetBy(dx: -margin, dy: -margin)
                return !placed.contains { $0.intersects(zone) }
                    && !entries.contains { $0.id != e.id && $0.badge.intersects(zone) }
            }
            if clear(rect(.above)) {
                result[e.id] = .above; placed.append(rect(.above))
            } else if clear(rect(.below)) {
                result[e.id] = .below; placed.append(rect(.below))
            } else {
                result[e.id] = .hidden
            }
        }
        return result
    }
}

/// Everything a pin map's camera depends on: when any of it changes the fit
/// is redone. Coordinates count as well as identities, so a pin that moves
/// under the same ID (a search swapping one place for another) is refitted.
struct PinnedMapFrame: Equatable {
    var size: CGSize
    var ids: [AnyHashable]
    var coordinates: [CLLocationCoordinate2D]
    /// How far the largest pin reaches past its coordinate on each side.
    var reach: EdgeInsets
    var area: EdgeInsets?

    static func == (a: PinnedMapFrame, b: PinnedMapFrame) -> Bool {
        a.size == b.size && a.ids == b.ids && a.reach == b.reach && a.area == b.area
            && a.coordinates.count == b.coordinates.count
            && zip(a.coordinates, b.coordinates).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
    }

    /// The camera rect keeping every pin whole at least `clearance` inside
    /// the area MapKit fits into (`safe`). The margins hold as given: pins
    /// never trade them for size. Nil without pins or before layout.
    func camera(safe: EdgeInsets, clearance: EdgeInsets) -> MKMapRect? {
        guard size.width > 0, size.height > 0,
              let content = voltaBounds(coordinates.map(MKMapPoint.init)) else { return nil }
        let insets = EdgeInsets(top: clearance.top + reach.top, leading: clearance.leading + reach.leading,
                                bottom: clearance.bottom + reach.bottom, trailing: clearance.trailing + reach.trailing)
        return TripRoute.fitted(content, size: size, safe: safe, insets: insets, strict: true)
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
