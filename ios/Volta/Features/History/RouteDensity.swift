import MapKit

/// Real road density for the heatmap. MapKit can't add stacked translucent
/// lines up into brighter colours, so this counts instead: recorded positions
/// are laid on a fixed ground grid (cells of about 35 m), each cell counts the
/// distinct drives that pass through it (a drive counts once per cell however
/// often it was sampled there or passed it), and the routes are cut into
/// strokes coloured by those counts. Pure and deterministic: the same drives
/// give the same strokes in the same order. Run it off the main thread.
enum RouteDensity {
    struct Drive: Sendable {
        var id: Int
        /// Recorded runs; never joined across a recording gap.
        var runs: [[CLLocationCoordinate2D]]
        /// Consumption over the efficiency reference, if the drive measured it.
        var ratio: Double?
    }

    struct Cell: Hashable, Sendable {
        var x: Int
        var y: Int
    }

    /// A run of consecutive cells of one drive that share a count.
    struct Stroke: Sendable, Equatable {
        var points: [MKMapPoint]
        var count: Int
        /// Distance-weighted average ratio of every drive in these cells; nil
        /// when none of them measured efficiency.
        var ratio: Double?

        static func == (a: Stroke, b: Stroke) -> Bool {
            a.count == b.count && a.ratio == b.ratio && a.points.count == b.points.count
                && zip(a.points, b.points).allSatisfy { $0.x == $1.x && $0.y == $1.y }
        }
    }

    struct Layer: Sendable {
        /// Lowest count first, so the busiest roads are drawn on top.
        var strokes: [Stroke]
        var counts: [Cell: Int]
        var maxCount: Int
        static let empty = Layer(strokes: [], counts: [:], maxCount: 0)
    }

    /// Ground size of a cell.
    static let cellMeters = 35.0
    /// Each drive is thinned to at most this many positions before counting,
    /// which keeps a few hundred loaded drives to well under a second.
    static let maxPointsPerDrive = 400

    /// Cell edge in map points. Map points stretch with latitude, so the edge
    /// is set for the 10° band the drives sit in; inside a band the grid is
    /// fixed and does not move as drives are loaded.
    static func cellSize(latitude: Double) -> Double {
        let band = max(-80, min(80, (latitude / 10).rounded() * 10))
        return cellMeters * MKMapPointsPerMeterAtLatitude(band)
    }

    static func build(_ drives: [Drive]) -> Layer {
        let ordered = drives.sorted { $0.id < $1.id }
        guard let anchor = ordered.lazy.flatMap({ $0.runs.joined() }).first else { return .empty }
        let cell = cellSize(latitude: anchor.latitude)

        // Pass 1: every drive's visits, cell by cell, in travel order.
        struct Visit { var cell: Cell; var from: MKMapPoint; var to: MKMapPoint; var length: Double }
        var visitsByDrive: [[[Visit]]] = []
        var counts: [Cell: Int] = [:]
        var ratioSum: [Cell: Double] = [:], ratioWeight: [Cell: Double] = [:]
        for drive in ordered {
            var seen = Set<Cell>()
            var runs: [[Visit]] = []
            for run in thin(drive.runs, to: maxPointsPerDrive) where run.count > 1 {
                var visits: [Visit] = []
                let points = run.map(MKMapPoint.init)
                for (a, b) in zip(points, points.dropFirst()) {
                    traverse(a, b, cell: cell) { c, from, to, length in
                        visits.append(Visit(cell: c, from: from, to: to, length: length))
                    }
                }
                for v in visits {
                    if seen.insert(v.cell).inserted { counts[v.cell, default: 0] += 1 }
                    if let ratio = drive.ratio, ratio.isFinite {
                        ratioSum[v.cell, default: 0] += ratio * v.length
                        ratioWeight[v.cell, default: 0] += v.length
                    }
                }
                runs.append(visits)
            }
            visitsByDrive.append(runs)
        }

        func ratio(_ c: Cell) -> Double? {
            guard let w = ratioWeight[c], w > 0, let s = ratioSum[c] else { return nil }
            return s / w
        }

        // Pass 2: join consecutive visits that look the same into strokes.
        var strokes: [Stroke] = []
        for runs in visitsByDrive {
            for visits in runs {
                var current: Stroke?
                for v in visits {
                    let count = counts[v.cell] ?? 1, r = ratio(v.cell)
                    if var s = current, s.count == count, s.ratio == r {
                        s.points.append(v.to)
                        current = s
                    } else {
                        if let s = current { strokes.append(s) }
                        current = Stroke(points: [v.from, v.to], count: count, ratio: r)
                    }
                }
                if let s = current { strokes.append(s) }
            }
        }
        // Stable: equal counts keep drive and travel order.
        let sorted = strokes.enumerated().sorted { ($0.element.count, $0.offset) < ($1.element.count, $1.offset) }.map(\.element)
        return Layer(strokes: sorted, counts: counts, maxCount: counts.values.max() ?? 0)
    }

    /// Visits every grid cell the segment passes through (Amanatides–Woo),
    /// with the part of the segment inside it. A touch shorter than a
    /// millionth of a cell (a corner graze) is not a visit.
    static func traverse(_ a: MKMapPoint, _ b: MKMapPoint, cell: Double,
                         visit: (Cell, MKMapPoint, MKMapPoint, Double) -> Void) {
        let ax = a.x / cell, ay = a.y / cell, bx = b.x / cell, by = b.y / cell
        let dx = bx - ax, dy = by - ay
        let length = hypot(dx, dy)
        var x = Int(floor(ax)), y = Int(floor(ay))
        guard length > 1e-9, ax.isFinite, ay.isFinite, bx.isFinite, by.isFinite else {
            visit(Cell(x: x, y: y), a, b, 0)
            return
        }
        let stepX = dx > 0 ? 1 : -1, stepY = dy > 0 ? 1 : -1
        var tMaxX = dx != 0 ? ((dx > 0 ? Double(x + 1) : Double(x)) - ax) / dx : .infinity
        var tMaxY = dy != 0 ? ((dy > 0 ? Double(y + 1) : Double(y)) - ay) / dy : .infinity
        let tDeltaX = dx != 0 ? 1 / abs(dx) : .infinity, tDeltaY = dy != 0 ? 1 / abs(dy) : .infinity
        func point(_ t: Double) -> MKMapPoint { MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        var t = 0.0
        for _ in 0..<100_000 {
            let next = min(tMaxX, tMaxY, 1)
            if (next - t) * length > 1e-6 { visit(Cell(x: x, y: y), point(t), point(next), (next - t) * length * cell) }
            if next >= 1 { return }
            t = next
            if tMaxX < tMaxY { x += stepX; tMaxX += tDeltaX } else { y += stepY; tMaxY += tDeltaY }
        }
    }

    /// Evenly thins a drive's runs to about `limit` positions in total,
    /// keeping every run's ends.
    static func thin(_ runs: [[CLLocationCoordinate2D]], to limit: Int) -> [[CLLocationCoordinate2D]] {
        let total = runs.reduce(0) { $0 + $1.count }
        guard total > limit, limit >= 2 else { return runs }
        let keep = Double(limit) / Double(total)
        return runs.map { run in
            guard run.count > 2 else { return run }
            let n = max(2, Int((Double(run.count) * keep).rounded()))
            let step = Double(run.count - 1) / Double(n - 1)
            return (0..<n).map { run[Int((Double($0) * step).rounded())] }
        }
    }
}

extension RouteDensity.Drive {
    /// A loaded drive's recorded runs, coloured against `reference`.
    init(_ drive: DriveSummary, reference: EfficiencyReference) {
        id = drive.id
        runs = DriveRouteSegments.runs(drive.drawableRoute).filter { $0.count > 1 }.map { run in
            run.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
        ratio = drive.displayEfficiencyWhPerKm.flatMap { $0.isFinite ? $0 / reference.whPerKm : nil }
    }
}
