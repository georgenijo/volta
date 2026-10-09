import Foundation

/// The HTTPS Volta endpoint. Redirects are rejected so tokens cannot cross hosts.
struct APIDataSource: VoltaDataSource {
    let baseURL: URL
    private let token: String
    private let session: URLSession
    private let onUnauthorized: @Sendable () async -> Void

    init(baseURL: URL, token: String, session: URLSession? = nil,
         onUnauthorized: @escaping @Sendable () async -> Void = {}) {
        self.baseURL = baseURL
        self.token = token
        self.session = session ?? Self.sharedSession
        self.onUnauthorized = onUnauthorized
    }

    static func validatedServerURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw VoltaError.transport("Enter an HTTPS server address without a path, credentials, or query.")
        }
        return url
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let ordinary = Date.ISO8601FormatStyle()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = (try? fractional.parse(value)) ?? (try? ordinary.parse(value)) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO-8601 timestamp"))
            }
            return date
        }
        return decoder
    }

    private static let sharedSession = makeSession()

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    private struct ErrorEnvelope: Decodable { let error: Payload; struct Payload: Decodable { let code: String; let message: String } }

    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil, authenticated: Bool = true) async throws -> Data {
        _ = try Self.validatedServerURL(baseURL.absoluteString)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/v1/" + path
        components.queryItems = query.isEmpty ? nil : query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw VoltaError.transport("Invalid request URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw VoltaError.transport("Invalid server response.") }
            if response.statusCode == 401 && authenticated {
                await onUnauthorized()
                throw VoltaError.unauthorized
            }
            guard (200..<300).contains(response.statusCode) else {
                let error = try? Self.makeDecoder().decode(ErrorEnvelope.self, from: data)
                if response.statusCode == 404 { throw VoltaError.notFound }
                if response.statusCode == 501, error?.error.code == "commands_unavailable" { throw VoltaError.commandsUnavailable }
                throw VoltaError.server(code: error?.error.code ?? "http_\(response.statusCode)", message: error?.error.message ?? "The server returned HTTP \(response.statusCode).")
            }
            return data
        } catch let error as VoltaError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw VoltaError.transport(error.localizedDescription) }
    }
    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await request(path, query: query)
        do { return try Self.makeDecoder().decode(T.self, from: data) }
        catch { throw VoltaError.transport("The server response could not be decoded.") }
    }
    private func listQuery(_ range: DateRange, _ cursor: String?) -> [URLQueryItem] {
        var query = [URLQueryItem(name: "limit", value: "100")]
        let formatter = ISO8601DateFormatter()
        if let from = range.from { query.append(URLQueryItem(name: "from", value: formatter.string(from: from))) }
        if let to = range.to { query.append(URLQueryItem(name: "to", value: formatter.string(from: to))) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return query
    }
    static func pair(baseURL: URL, code: String, deviceName: String, session: URLSession? = nil) async throws -> PairResponse {
        let body = try JSONEncoder().encode(["code": code, "deviceName": deviceName])
        let source = APIDataSource(baseURL: baseURL, token: "", session: session)
        let data = try await source.request("auth/pair", method: "POST", body: body, authenticated: false)
        do { return try makeDecoder().decode(PairResponse.self, from: data) }
        catch { throw VoltaError.transport("The pairing response could not be decoded.") }
    }
    func health() async throws -> HealthResponse {
        let data = try await request("health", authenticated: false)
        do { return try Self.makeDecoder().decode(HealthResponse.self, from: data) }
        catch { throw VoltaError.transport("The health response could not be decoded.") }
    }
    func me() async throws -> Device { try await get("me") }
    func revoke() async throws { _ = try await request("me", method: "DELETE") }
    func vehicles() async throws -> [Vehicle] { try await get("vehicles") }
    func status(vehicleID: Int) async throws -> VehicleStatus { try await get("vehicles/\(vehicleID)/status") }
    func summary(vehicleID: Int, range: SummaryRange) async throws -> ActivitySummary {
        var query = [URLQueryItem(name: "range", value: range.rawValue)]
        if let tz = Self.summaryTimeZone() { query.append(.init(name: "tz", value: tz)) }
        return try await get("vehicles/\(vehicleID)/summary", query: query)
    }
    /// `tz` for `/summary`: the device's IANA zone, so `today` starts at local
    /// midnight (servers predating the parameter ignore it). Zones without an
    /// IANA name (fixed offsets) are omitted; the server then uses UTC.
    static func summaryTimeZone(_ zone: TimeZone = .current) -> String? {
        TimeZone.knownTimeZoneIdentifiers.contains(zone.identifier) ? zone.identifier : nil
    }
    func timeline(vehicleID: Int, hours: Int) async throws -> [TimelineSegment] { try await get("vehicles/\(vehicleID)/timeline", query: [.init(name: "hours", value: String(hours))]) }
    func drives(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<DriveSummary> { try await get("vehicles/\(vehicleID)/drives", query: listQuery(range, cursor)) }
    func drive(id: Int) async throws -> DriveDetail { try await get("drives/\(id)") }
    func charges(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<ChargeSummary> { try await get("vehicles/\(vehicleID)/charges", query: listQuery(range, cursor)) }
    func charge(id: Int) async throws -> ChargeDetail { try await get("charges/\(id)") }
    func idles(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<IdleSummary> { try await get("vehicles/\(vehicleID)/idles", query: listQuery(range, cursor) + [.init(name: "minMinutes", value: "10")]) }
    func battery(vehicleID: Int) async throws -> BatteryHealth { try await get("vehicles/\(vehicleID)/battery") }
    func mileage(vehicleID: Int, bucket: MileageBucketSize) async throws -> [MileageBucket] { try await get("vehicles/\(vehicleID)/mileage", query: [.init(name: "bucket", value: bucket.rawValue)]) }
    func firmware(vehicleID: Int) async throws -> [FirmwareUpdate] { try await get("vehicles/\(vehicleID)/firmware") }
    func places(vehicleID: Int) async throws -> [Place] { try await get("vehicles/\(vehicleID)/places") }
    func command(vehicleID: Int, name: String, params: [String: String]) async throws {
        // Phase 1 never sends a vehicle command.
        throw VoltaError.commandsUnavailable
    }
}

extension APIDataSource: TeslaAccountClient {
    func teslaStatus() async throws -> TeslaStatus { try await get("tesla/status") }
    func startTeslaLink() async throws -> TeslaLinkStart {
        try decodeTesla(try await request("tesla/link", method: "POST", body: Data("{}".utf8)))
    }
    func completeTeslaLink(callbackURL: URL) async throws -> TeslaStatus {
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        let body = try encoder.encode(["callbackUrl": callbackURL.absoluteString])
        return try decodeTesla(try await request("tesla/link/complete", method: "POST", body: body))
    }
    func cancelTeslaLink() async throws { _ = try await request("tesla/link", method: "DELETE") }
    func disconnectTesla() async throws { _ = try await request("tesla/account", method: "DELETE") }
    private func decodeTesla<T: Decodable>(_ data: Data) throws -> T {
        do { return try Self.makeDecoder().decode(T.self, from: data) }
        catch { throw VoltaError.transport("The server response could not be decoded.") }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

extension APIDataSource {
    func service(vehicleID: Int) async throws -> ServiceState { try await get("vehicles/\(vehicleID)/service") }
    func addService(vehicleID: Int, item: ServiceItemInput) async throws {
        _ = try await request("vehicles/\(vehicleID)/service", method: "POST", body: JSONEncoder().encode(item))
    }
    func completeService(vehicleID: Int, itemID: String, event: ServiceEventInput) async throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        _ = try await request("vehicles/\(vehicleID)/service/\(itemID)/events", method: "POST", body: encoder.encode(event))
    }
    func updateService(vehicleID: Int, itemID: String, item: ServiceItemInput) async throws {
        _ = try await request("vehicles/\(vehicleID)/service/\(itemID)", method: "PATCH", body: JSONEncoder().encode(item))
    }
    func deleteService(vehicleID: Int, itemID: String) async throws {
        _ = try await request("vehicles/\(vehicleID)/service/\(itemID)", method: "DELETE")
    }
    func updateServiceEvent(vehicleID: Int, eventID: String, event: ServiceEventInput) async throws {
        let encoder=JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        _ = try await request("vehicles/\(vehicleID)/service-events/\(eventID)", method: "PATCH", body: encoder.encode(event))
    }
    func deleteServiceEvent(vehicleID: Int, eventID: String) async throws {
        _ = try await request("vehicles/\(vehicleID)/service-events/\(eventID)", method: "DELETE")
    }
    func chargerLocations(vehicleID: Int) async throws -> [ChargerLocation] { try await get("vehicles/\(vehicleID)/charger-locations") }
    func chargerSessions(vehicleID: Int, locationID: String, cursor: String?) async throws -> Page<ChargeSummary> {
        try await get("vehicles/\(vehicleID)/charger-locations/\(locationID)/sessions", query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
    }
}
