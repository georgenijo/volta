import Foundation

/// Synthetic demo routes between public Bay Area landmarks. Waypoints trace
/// the general line of public corridors (the Caltrain line beside Alma Street
/// and Central Expressway, Shoreline Boulevard, Page Mill Road, Palm Drive) so
/// demo maps show road-shaped routes. Generated geometry, not a recording.
enum DemoRoutes {
    struct Route {
        var from: String
        var to: String
        var waypoints: [(lat: Double, lon: Double)]
    }

    static let all: [Route] = [
        // Menlo Park → Mountain View along the rail corridor.
        Route(from: "Menlo Park", to: "Mountain View", waypoints: [
            (37.4545, -122.1823), (37.4500, -122.1760), (37.4434, -122.1650), (37.4380, -122.1570),
            (37.4290, -122.1420), (37.4215, -122.1310), (37.4140, -122.1190), (37.4072, -122.1074),
            (37.4015, -122.0950), (37.3975, -122.0840), (37.3947, -122.0760),
        ]),
        // Mountain View → Sunnyvale on the expressway beside the tracks.
        Route(from: "Mountain View", to: "Sunnyvale", waypoints: [
            (37.3947, -122.0760), (37.3925, -122.0690), (37.3890, -122.0590), (37.3850, -122.0480),
            (37.3815, -122.0390), (37.3784, -122.0308), (37.3755, -122.0200), (37.3730, -122.0090),
        ]),
        // Downtown Mountain View → Shoreline, north across the freeway.
        Route(from: "Mountain View", to: "Mountain View", waypoints: [
            (37.3930, -122.0790), (37.3965, -122.0805), (37.4010, -122.0810), (37.4060, -122.0795),
            (37.4110, -122.0782), (37.4160, -122.0790), (37.4215, -122.0800), (37.4268, -122.0806),
        ]),
        // Palo Alto → Stanford up Palm Drive.
        Route(from: "Palo Alto", to: "Stanford", waypoints: [
            (37.4434, -122.1650), (37.4418, -122.1662), (37.4395, -122.1672), (37.4362, -122.1682),
            (37.4330, -122.1690), (37.4300, -122.1695), (37.4275, -122.1700),
        ]),
        // California Avenue → Los Altos Hills on Page Mill Road.
        Route(from: "Palo Alto", to: "Los Altos Hills", waypoints: [
            (37.4290, -122.1420), (37.4255, -122.1452), (37.4205, -122.1478), (37.4150, -122.1500),
            (37.4090, -122.1528), (37.4040, -122.1560), (37.3990, -122.1590), (37.3940, -122.1640),
        ]),
    ]

    static func route(for driveID: Int) -> Route { all[((driveID % all.count) + all.count) % all.count] }

    /// The route as timed points at roughly `spacingM` metres, corners rounded
    /// like road curves. Even drive ids run it in reverse so trips return.
    static func points(for driveID: Int, start: Date, durationMin: Double, spacingM: Double = 80) -> [DriveRoutePoint] {
        var waypoints = route(for: driveID).waypoints
        if driveID % 2 == 0 { waypoints.reverse() }
        let smooth = chaikin(chaikin(waypoints))
        var dense: [(lat: Double, lon: Double)] = [smooth[0]]
        for (a, b) in zip(smooth, smooth.dropFirst()) {
            let steps = max(1, Int((meters(a, b) / spacingM).rounded(.up)))
            for step in 1...steps {
                let u = Double(step) / Double(steps)
                dense.append((a.lat + (b.lat - a.lat) * u, a.lon + (b.lon - a.lon) * u))
            }
        }
        let total = max(durationMin * 60, 1)
        return dense.enumerated().map { index, point in
            DriveRoutePoint(t: start.addingTimeInterval(total * Double(index) / Double(max(dense.count - 1, 1))),
                            latitude: point.lat, longitude: point.lon)
        }
    }

    /// Start and end names for the drive's route, in travel order.
    static func places(for driveID: Int) -> (from: String, to: String) {
        let route = route(for: driveID)
        return driveID % 2 == 0 ? (route.to, route.from) : (route.from, route.to)
    }

    /// One Chaikin pass: rounds corners, keeps both endpoints.
    private static func chaikin(_ points: [(lat: Double, lon: Double)]) -> [(lat: Double, lon: Double)] {
        guard points.count > 2 else { return points }
        var result = [points[0]]
        for (a, b) in zip(points, points.dropFirst()) {
            result.append((a.lat * 0.75 + b.lat * 0.25, a.lon * 0.75 + b.lon * 0.25))
            result.append((a.lat * 0.25 + b.lat * 0.75, a.lon * 0.25 + b.lon * 0.75))
        }
        result.append(points[points.count - 1])
        return result
    }

    private static func meters(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let dLat = (b.lat - a.lat) * 111_195
        let dLon = (b.lon - a.lon) * 111_195 * cos(a.lat * .pi / 180)
        return hypot(dLat, dLon)
    }
}
