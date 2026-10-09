import Foundation

struct ServiceItemInput: Codable, Sendable {
    var name: String
    var intervalKm: Double? = nil
    var intervalMonths: Int? = nil
    static let presets: [Self] = [
        .init(name: "Tire rotation", intervalKm: 6250 * 1.609344),
        .init(name: "Cabin air filter", intervalMonths: 24),
        .init(name: "Brake fluid check", intervalMonths: 48),
        .init(name: "Wiper blades", intervalMonths: 12)
    ]
}
struct ServiceEventInput: Codable, Sendable {
    var completedAt: Date
    var odometerKm: Double?
}
struct ServiceItem: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var intervalKm: Double? = nil
    var intervalMonths: Int? = nil
    var nextDate: Date?
    var nextOdometerKm: Double?
    var remainingKm: Double?
    var remainingDays: Int?
    var progress: Double?
}
struct ServiceEvent: Codable, Sendable, Identifiable {
    var id: String
    var itemId: String
    var completedAt: Date
    var odometerKm: Double?
}
struct ServiceState: Codable, Sendable {
    var odometerKm: Double?
    var recordedAt: Date?
    var source: String?
    var items: [ServiceItem]
    var events: [ServiceEvent]
}
struct ChargerLocation: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var latitude: Double?
    var longitude: Double?
    var sessionCount: Int
    var lastVisit: Date
    var energyAddedKwh: Double?
    var avgPowerKw: Double?
    var powerSessionCount: Int
    var cost: Double?
    var currency: String?
    var hasCoordinate: Bool {
        guard let latitude, let longitude else { return false }
        return latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}
