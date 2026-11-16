import Foundation

/// `GET /v1/vehicles/{id}/tires`: each wheel's recorded pressure, thinned by
/// the server to one point per local day (or ISO week for long spans). A
/// bucket without a reading is absent; a wheel whose sensor never reported in
/// the span has no points. Pressures are bar, as TeslaMate records them.
struct TirePressureHistory: Codable, Hashable, Sendable {
    enum Bucket: String, Codable, Hashable, Sendable { case day, week }

    struct Point: Codable, Hashable, Sendable {
        /// Start of the local day or week, as an instant.
        var start: Date
        var minBar: Double
        var avgBar: Double
        var maxBar: Double
        var readings: Int
        var firstAt: Date
        var lastAt: Date
        /// Same-moment comparison with the other tyres: readings in the bucket
        /// where this wheel and at least two others reported together, the
        /// mean of (this wheel − the others' mean) over them, and the others'
        /// mean. Absent from older servers; nil when no reading qualified.
        var peerReadings: Int? = nil
        var peerDeltaBar: Double? = nil
        var peerBar: Double? = nil
        /// How many other wheels read in every one of those readings (2 or 3);
        /// nil when it varied, so the app never names more tyres than took part.
        var peerWheels: Int? = nil
    }

    struct Wheels: Codable, Hashable, Sendable {
        var fl: [Point]
        var fr: [Point]
        var rl: [Point]
        var rr: [Point]

        subscript(_ wheel: TireWheel) -> [Point] {
            get {
                switch wheel {
                case .fl: fl
                case .fr: fr
                case .rl: rl
                case .rr: rr
                }
            }
            set {
                switch wheel {
                case .fl: fl = newValue
                case .fr: fr = newValue
                case .rl: rl = newValue
                case .rr: rr = newValue
                }
            }
        }
    }

    var bucket: Bucket
    var timeZone: String?
    var from: Date?
    var to: Date
    var firstReadingAt: Date?
    var lastReadingAt: Date?
    var wheels: Wheels

    var isEmpty: Bool { TireWheel.allCases.allSatisfy { wheels[$0].isEmpty } }
}

enum TireWheel: String, CaseIterable, Hashable, Sendable, Identifiable {
    case fl, fr, rl, rr
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fl: "Front left"
        case .fr: "Front right"
        case .rl: "Rear left"
        case .rr: "Rear right"
        }
    }
    var short: String { rawValue.uppercased() }
}
