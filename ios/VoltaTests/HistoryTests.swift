import XCTest
@testable import Volta

private struct Row: Codable, Hashable, Sendable, Identifiable { var id: Int }

/// Hands out fetches that stay pending until the test resolves them.
@MainActor private final class Gate {
    struct Request {
        var cursor: String?
        var continuation: CheckedContinuation<Page<Row>, Error>
    }
    private(set) var requests: [Request] = []
    private var resolved = 0

    var fetch: HistoryFeed<Row>.Fetch {
        { [self] _, cursor in try await self.wait(cursor) }
    }

    private func wait(_ cursor: String?) async throws -> Page<Row> {
        try await withCheckedThrowingContinuation { requests.append(Request(cursor: cursor, continuation: $0)) }
    }

    var pending: Int { requests.count - resolved }

    /// Resolves the request at `index` (in arrival order).
    func succeed(_ index: Int, ids: [Int], next: String?) {
        requests[index].continuation.resume(returning: Page(items: ids.map(Row.init), nextCursor: next))
        resolved += 1
    }

    func fail(_ index: Int, _ message: String = "boom") {
        requests[index].continuation.resume(throwing: VoltaError.transport(message))
        resolved += 1
    }
}

@MainActor private func settle(until condition: () -> Bool = { false }, _ file: StaticString = #filePath, _ line: UInt = #line) async {
    for _ in 0..<200 {
        if condition() { return }
        await Task.yield()
    }
    if !condition() { XCTFail("condition never became true", file: file, line: line) }
}

@MainActor private func drain() async { for _ in 0..<50 { await Task.yield() } }

@MainActor final class HistoryFeedTests: XCTestCase {
    private let range = DateRange(from: nil, to: nil)

    private func loadedFeed(_ gate: Gate, ids: [Int], next: String?) async -> HistoryFeed<Row> {
        let feed = HistoryFeed<Row>()
        let task = Task { await feed.reload(range: range, fetch: gate.fetch, showSkeleton: true) }
        await settle { gate.requests.count == 1 }
        gate.succeed(0, ids: ids, next: next)
        await task.value
        return feed
    }

    func testFirstPageThenPaginationAppendsAndAdvancesCursor() async {
        let gate = Gate()
        let feed = await loadedFeed(gate, ids: [5, 4], next: "A")
        XCTAssertEqual(feed.phase, .loaded)
        XCTAssertEqual(feed.items.map(\.id), [5, 4])
        XCTAssertTrue(feed.canLoadMore)

        let more = Task { await feed.loadMore() }
        await settle { gate.requests.count == 2 }
        XCTAssertEqual(gate.requests[1].cursor, "A")
        XCTAssertTrue(feed.isLoadingMore)
        // A second trigger while loading is a no-op.
        await feed.loadMore()
        XCTAssertEqual(gate.requests.count, 2)
        gate.succeed(1, ids: [4, 3], next: nil)  // duplicate 4 is dropped
        await more.value
        XCTAssertEqual(feed.items.map(\.id), [5, 4, 3])
        XCTAssertNil(feed.nextCursor)
        XCTAssertFalse(feed.isLoadingMore)
        XCTAssertFalse(feed.canLoadMore)
        await feed.loadMore()
        XCTAssertEqual(gate.requests.count, 2, "no request past the last page")
    }

    /// Finding 1: starting a page load must not change the footer's task id.
    func testPaginationTriggerIsStableWhileLoading() async {
        let gate = Gate()
        let feed = await loadedFeed(gate, ids: [2], next: "A")
        let before = feed.paginationTrigger
        XCTAssertFalse(before.blocked)
        let more = Task { await feed.loadMore() }
        await settle { feed.isLoadingMore }
        XCTAssertEqual(feed.paginationTrigger, before)
        gate.succeed(1, ids: [1], next: "B")
        await more.value
        XCTAssertEqual(feed.paginationTrigger, .init(cursor: "B", blocked: false))
    }

    /// Finding 2: pagination is blocked while a refresh runs.
    func testPaginationBlockedDuringRefresh() async {
        let gate = Gate()
        let feed = await loadedFeed(gate, ids: [4, 3], next: "A")
        let refresh = Task { await feed.reload(range: range, fetch: gate.fetch) }
        await settle { gate.requests.count == 2 }
        XCTAssertTrue(feed.isRefreshing)
        XCTAssertTrue(feed.paginationTrigger.blocked)
        XCTAssertEqual(feed.items.map(\.id), [4, 3], "rows stay visible during refresh")
        await feed.loadMore()
        XCTAssertEqual(gate.requests.count, 2, "no page request during refresh")
        gate.succeed(1, ids: [5, 4], next: "B")
        await refresh.value
        XCTAssertEqual(feed.items.map(\.id), [5, 4])
        XCTAssertEqual(feed.nextCursor, "B")
        XCTAssertFalse(feed.paginationTrigger.blocked)
    }

    /// Finding 2 reproduction: a page that was in flight when the refresh
    /// started must not append to or overwrite the refreshed list's cursor.
    func testRefreshInvalidatesOutstandingPagination() async {
        let gate = Gate()
        let feed = await loadedFeed(gate, ids: [4, 3], next: "A")
        let more = Task { await feed.loadMore() }
        await settle { gate.requests.count == 2 }
        let refresh = Task { await feed.reload(range: range, fetch: gate.fetch) }
        await settle { gate.requests.count == 3 }
        XCTAssertFalse(feed.isLoadingMore)
        gate.succeed(2, ids: [5, 4, 3], next: "B")
        await refresh.value
        // The stale page (old cursor "A") arrives after the refresh.
        gate.succeed(1, ids: [1], next: nil)
        await more.value
        XCTAssertEqual(feed.items.map(\.id), [5, 4, 3])
        XCTAssertEqual(feed.nextCursor, "B", "stale page must not clear the refreshed cursor")
        // Continuing from the refreshed cursor reaches the remaining records.
        let next = Task { await feed.loadMore() }
        await settle { gate.requests.count == 4 }
        XCTAssertEqual(gate.requests[3].cursor, "B")
        gate.succeed(3, ids: [2, 1], next: nil)
        await next.value
        XCTAssertEqual(feed.items.map(\.id), [5, 4, 3, 2, 1])
    }

    func testFailedRefreshKeepsRowsAndCursor() async {
        let gate = Gate()
        let feed = await loadedFeed(gate, ids: [3], next: "A")
        let refresh = Task { await feed.reload(range: range, fetch: gate.fetch) }
        await settle { gate.requests.count == 2 }
        gate.fail(1, "offline")
        await refresh.value
        XCTAssertEqual(feed.phase, .loaded)
        XCTAssertEqual(feed.items.map(\.id), [3])
        XCTAssertEqual(feed.nextCursor, "A")
        XCTAssertNotNil(feed.refreshError)
        XCTAssertEqual(feed.footerError, feed.refreshError)
        XCTAssertFalse(feed.isRefreshing)
    }

    func testPageErrorBlocksAutoRetryUntilExplicitRetry() async {
        let gate = Gate()
        let feed = await loadedFeed(gate, ids: [3], next: "A")
        let more = Task { await feed.loadMore() }
        await settle { gate.requests.count == 2 }
        gate.fail(1)
        await more.value
        XCTAssertNotNil(feed.loadMoreError)
        XCTAssertTrue(feed.paginationTrigger.blocked)
        await feed.loadMore()
        XCTAssertEqual(gate.requests.count, 2, "footer task must not hammer a failing page")
        let retry = Task { await feed.retryLoadMore() }
        await settle { gate.requests.count == 3 }
        XCTAssertNil(feed.loadMoreError)
        gate.succeed(2, ids: [2], next: nil)
        await retry.value
        XCTAssertEqual(feed.items.map(\.id), [3, 2])
    }

    func testFirstLoadFailureShowsErrorPhase() async {
        let gate = Gate()
        let feed = HistoryFeed<Row>()
        let task = Task { await feed.reload(range: range, fetch: gate.fetch, showSkeleton: true) }
        await settle { gate.requests.count == 1 }
        XCTAssertEqual(feed.phase, .loading)
        gate.fail(0, "down")
        await task.value
        guard case .failed = feed.phase else { return XCTFail("expected failed phase") }
        XCTAssertTrue(feed.items.isEmpty)
        XCTAssertFalse(feed.canLoadMore)
    }

    func testNewerReloadWinsOverOlderOne() async {
        let gate = Gate()
        let feed = HistoryFeed<Row>()
        let first = Task { await feed.reload(range: range, fetch: gate.fetch, showSkeleton: true) }
        await settle { gate.requests.count == 1 }
        let second = Task { await feed.reload(range: range, fetch: gate.fetch, showSkeleton: true) }
        await settle { gate.requests.count == 2 }
        gate.succeed(1, ids: [9], next: nil)
        await second.value
        gate.succeed(0, ids: [1], next: "old")
        await first.value
        XCTAssertEqual(feed.items.map(\.id), [9])
        XCTAssertNil(feed.nextCursor)
    }
}

final class HistoryAggregateTests: XCTestCase {
    private func charge(_ id: Int, kwh: Double?, cost: Double?, currency: String?) -> ChargeSummary {
        ChargeSummary(id: id, start: .init(timeIntervalSince1970: 0), end: nil, address: nil, placeName: nil,
                      energyAddedKwh: kwh, energyUsedKwh: nil, startBatteryLevel: nil, endBatteryLevel: nil,
                      durationMin: 60, maxPowerKw: nil, fastCharger: false, cost: cost, currency: currency, outsideTempAvgC: nil)
    }

    private func idle(_ id: Int, minutes: Double, start: Int?, end: Int?, rangeLost: Double? = nil,
                      sentry: Double? = nil, climate: Double? = nil, asleep: Double? = nil) -> IdleSummary {
        IdleSummary(id: id, start: .init(timeIntervalSince1970: 0), end: nil, address: nil, placeName: nil,
                    durationMin: minutes, startBatteryLevel: start, endBatteryLevel: end, rangeLostKm: rangeLost,
                    energyLostKwh: nil, sentryMinutes: sentry, climateMinutes: climate, asleepMinutes: asleep)
    }

    private func drive(_ id: Int, km: Double, kwh: Double?, start: Int? = 80, end: Int? = 70) -> DriveSummary {
        DriveSummary(id: id, start: .init(timeIntervalSince1970: 0), end: nil, startAddress: nil, endAddress: nil,
                     distanceKm: km, durationMin: 10, startBatteryLevel: start, endBatteryLevel: end,
                     energyUsedKwh: kwh, efficiencyWhPerKm: nil, maxSpeedKph: nil, avgSpeedKph: nil, outsideTempAvgC: nil)
    }

    // Finding 5
    func testCostsAreNeverSummedAcrossCurrencies() {
        let single = CostTotal([charge(1, kwh: 1, cost: 2, currency: "USD"), charge(2, kwh: 1, cost: 3, currency: nil)],
                               fallbackCurrency: "USD")
        XCTAssertEqual(single, .single(amount: 5, currency: "USD"))
        let mixed = CostTotal([charge(1, kwh: 1, cost: 2, currency: "USD"), charge(2, kwh: 1, cost: 3, currency: "EUR"),
                               charge(3, kwh: 1, cost: 4, currency: "usd")], fallbackCurrency: "USD")
        XCTAssertEqual(mixed, .mixed(["USD": 6, "EUR": 3]))
        XCTAssertEqual(mixed.display, "Mixed")
        XCTAssertNotNil(mixed.breakdown)
        XCTAssertTrue(ChargingTotals([charge(1, kwh: 1, cost: 2, currency: "USD"), charge(2, kwh: 1, cost: 3, currency: "EUR")],
                                     fallbackCurrency: "USD").notes.contains { $0.hasPrefix("Cost by currency") })
        XCTAssertEqual(CostTotal([charge(1, kwh: 1, cost: nil, currency: "USD")], fallbackCurrency: "USD"), .none)
        XCTAssertEqual(CostTotal.none.display, "—")
    }

    // Finding 6
    func testMissingMeasurementsStayUnknown() {
        let none = ChargingTotals([charge(1, kwh: nil, cost: nil, currency: nil)], fallbackCurrency: "USD")
        XCTAssertNil(none.energyAddedKwh.value, "no recorded energy must not become 0 kWh")
        XCTAssertEqual(none.cost, .none)
        XCTAssertTrue(none.notes.isEmpty)

        let partial = ChargingTotals([charge(1, kwh: 10, cost: 1, currency: "USD"), charge(2, kwh: nil, cost: nil, currency: nil)],
                                     fallbackCurrency: "USD")
        XCTAssertEqual(partial.energyAddedKwh.value, 10)
        XCTAssertTrue(partial.energyAddedKwh.isPartial)
        XCTAssertEqual(partial.notes.count, 2)

        let idles = IdleTotals([idle(1, minutes: 60, start: nil, end: nil), idle(2, minutes: 120, start: nil, end: nil)])
        XCTAssertNil(idles.rangeLostKm.value)
        XCTAssertNil(idles.drainPerDay, "no battery data must not be 0 %/day")
        XCTAssertEqual(idles.parkedMinutes, 180)

        // Rate only over time with a known drain: 2 % over 12 h = 4 %/day, not 2 % over 36 h.
        let rated = IdleTotals([idle(1, minutes: 720, start: 80, end: 78, rangeLost: 5),
                                idle(2, minutes: 1440, start: nil, end: nil)])
        XCTAssertEqual(try XCTUnwrap(rated.drainPerDay), 4, accuracy: 1e-9)
        XCTAssertEqual(rated.drainKnown, 1)
        XCTAssertTrue(rated.rangeLostKm.isPartial)
        XCTAssertEqual(rated.notes.count, 2)

        let drives = DriveTotals([drive(1, km: 10, kwh: 1.5), drive(2, km: 90, kwh: nil)])
        XCTAssertEqual(try XCTUnwrap(drives.efficiencyWhPerKm), 150, accuracy: 1e-9)
        XCTAssertEqual(drives.distanceKm, 100)
        XCTAssertEqual(drives.notes.count, 1)
        XCTAssertNil(DriveTotals([drive(1, km: 10, kwh: nil)]).efficiencyWhPerKm)
    }

    // Finding 7
    func testTotalsScopeIsPartialWhileACursorRemains() {
        XCTAssertEqual(HistoryTotalsScope.title(period: "Last 30 days", hasMore: true, noun: "sessions"), "Loaded sessions — partial")
        XCTAssertEqual(HistoryTotalsScope.title(period: "Last 30 days", hasMore: true, noun: "drives"), "Loaded drives — partial")
        XCTAssertEqual(HistoryTotalsScope.title(period: "Last 30 days", hasMore: false, noun: "sessions"), "Last 30 days")
    }

    // Finding 8
    func testIdleRemainderIsUnclassifiedUnlessAllStatesKnown() {
        let partial = idle(1, minutes: 600, start: nil, end: nil, sentry: 60, asleep: 300).breakdown
        XCTAssertEqual(partial.map(\.kind), [.sentry, .unclassified, .asleep])
        XCTAssertEqual(partial.first { $0.kind == .unclassified }?.minutes, 240)
        XCTAssertFalse(partial.contains { $0.kind == .awake })

        let complete = idle(2, minutes: 600, start: nil, end: nil, sentry: 60, climate: 0, asleep: 300).breakdown
        XCTAssertEqual(complete.map(\.kind), [.sentry, .awake, .asleep])
        XCTAssertEqual(complete.first { $0.kind == .awake }?.minutes, 240)

        XCTAssertTrue(idle(3, minutes: 600, start: nil, end: nil).breakdown.isEmpty)
    }

    // Finding 12
    func testBatteryEndpointsRunStartToEnd() {
        let d = drive(1, km: 10, kwh: 1, start: 80, end: 64).batteryEndpoints
        XCTAssertEqual(d.from, 80); XCTAssertEqual(d.to, 64)
        let i = idle(1, minutes: 60, start: 74, end: 72).batteryEndpoints
        XCTAssertEqual(i.from, 74); XCTAssertEqual(i.to, 72)
        var c = charge(1, kwh: 1, cost: nil, currency: nil)
        c.startBatteryLevel = 49; c.endBatteryLevel = 80
        XCTAssertEqual(c.batteryEndpoints.from, 49); XCTAssertEqual(c.batteryEndpoints.to, 80)
    }
}

final class HistoryRouteAndChartTests: XCTestCase {
    private func point(_ s: Double, speed: Double?, power: Double?) -> DrivePoint {
        DrivePoint(t: .init(timeIntervalSince1970: s), latitude: 37, longitude: -122, speedKph: speed, powerKw: power,
                   elevationM: nil, batteryLevel: nil)
    }

    // Finding 10
    func testEfficiencyUsesOnlyPairedSamples() {
        // Missing power must not read as 0 Wh/km (excellent efficiency).
        XCTAssertNil(RouteBuilder.efficiencyWhPerKm([point(0, speed: 80, power: nil), point(1, speed: 90, power: nil)]))
        XCTAssertEqual(RouteBuilder.color(for: nil, coloring: .efficiency), HistoryTheme.secondary)
        // Unpaired samples are ignored rather than averaged in as zeros.
        let mixed = [point(0, speed: 100, power: 15), point(1, speed: 100, power: nil), point(2, speed: nil, power: 30)]
        XCTAssertEqual(try XCTUnwrap(RouteBuilder.efficiencyWhPerKm(mixed)), 150, accuracy: 1e-9)
        // Stationary samples give no meaningful rate.
        XCTAssertNil(RouteBuilder.efficiencyWhPerKm([point(0, speed: 0, power: 5)]))
        // Regen is still negative.
        XCTAssertLessThan(try XCTUnwrap(RouteBuilder.efficiencyWhPerKm([point(0, speed: 50, power: -20)])), 0)

        let segments = RouteBuilder.segments([point(0, speed: 80, power: nil), point(1, speed: 80, power: nil)], coloring: .efficiency)
        XCTAssertEqual(segments.map(\.color), [HistoryTheme.secondary])
    }

    // Finding 11
    func testRouteStateDistinguishesLoadedWithoutRoute() {
        let summary = DriveSummary(id: 1, start: .init(timeIntervalSince1970: 0), end: nil, startAddress: nil, endAddress: nil,
                                   distanceKm: 1, durationMin: 1, startBatteryLevel: nil, endBatteryLevel: nil, energyUsedKwh: nil,
                                   efficiencyWhPerKm: nil, maxSpeedKph: nil, avgSpeedKph: nil, outsideTempAvgC: nil)
        XCTAssertEqual(RouteMapState(detail: nil, error: nil), .loading)
        XCTAssertEqual(RouteMapState(detail: nil, error: "x"), .failed("x"))
        XCTAssertEqual(RouteMapState(detail: DriveDetail(summary: summary, path: [], elevationGainM: nil), error: nil), .notRecorded)
        let one = point(0, speed: nil, power: nil)
        XCTAssertEqual(RouteMapState(detail: DriveDetail(summary: summary, path: [one], elevationGainM: nil), error: nil), .single(one))
        let two = [one, point(1, speed: nil, power: nil)]
        XCTAssertEqual(RouteMapState(detail: DriveDetail(summary: summary, path: two, elevationGainM: nil), error: nil), .route(two))
    }

    // Finding 4
    func testDownsamplePreservesExtremesAndBoundsSize() {
        let start = Date(timeIntervalSince1970: 0)
        var points = (0..<20_000).map { HistoryChartPoint(t: start.addingTimeInterval(Double($0)), value: sin(Double($0) / 50)) }
        points[7_777].value = 50
        points[12_345].value = -50
        let out = HistorySeries.downsample(points, maxPoints: 500)
        XCTAssertLessThanOrEqual(out.count, 500)
        XCTAssertEqual(out.first, points.first)
        XCTAssertEqual(out.last, points.last)
        XCTAssertTrue(out.contains(points[7_777]))
        XCTAssertTrue(out.contains(points[12_345]))
        XCTAssertEqual(out.map(\.t), out.map(\.t).sorted())
        XCTAssertEqual(Set(out.map(\.t)).count, out.count, "no duplicate points")
        let small = Array(points.prefix(100))
        XCTAssertEqual(HistorySeries.downsample(small), small)
        let domain = HistorySeries.domain(out)
        XCTAssertLessThanOrEqual(domain.lowerBound, -50)
        XCTAssertGreaterThanOrEqual(domain.upperBound, 50)
    }
}

/// Mock data except `/places`, which fails.
private struct PlacesFailingSource: VoltaDataSource {
    private let base = MockDataSource()
    func vehicles() async throws -> [Vehicle] { try await base.vehicles() }
    func status(vehicleID: Int) async throws -> VehicleStatus { try await base.status(vehicleID: vehicleID) }
    func summary(vehicleID: Int, range: SummaryRange) async throws -> ActivitySummary { try await base.summary(vehicleID: vehicleID, range: range) }
    func timeline(vehicleID: Int, hours: Int) async throws -> [TimelineSegment] { try await base.timeline(vehicleID: vehicleID, hours: hours) }
    func drives(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<DriveSummary> { try await base.drives(vehicleID: vehicleID, range: range, cursor: cursor) }
    func drive(id: Int) async throws -> DriveDetail { try await base.drive(id: id) }
    func charges(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<ChargeSummary> { try await base.charges(vehicleID: vehicleID, range: range, cursor: cursor) }
    func charge(id: Int) async throws -> ChargeDetail { try await base.charge(id: id) }
    func idles(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<IdleSummary> { try await base.idles(vehicleID: vehicleID, range: range, cursor: cursor) }
    func battery(vehicleID: Int) async throws -> BatteryHealth { try await base.battery(vehicleID: vehicleID) }
    func mileage(vehicleID: Int, bucket: MileageBucketSize) async throws -> [MileageBucket] { try await base.mileage(vehicleID: vehicleID, bucket: bucket) }
    func firmware(vehicleID: Int) async throws -> [FirmwareUpdate] { try await base.firmware(vehicleID: vehicleID) }
    func places(vehicleID: Int) async throws -> [Place] { throw VoltaError.transport("places down") }
    func command(vehicleID: Int, name: String, params: [String: String]) async throws { throw VoltaError.commandsUnavailable }
}

final class HistoryLocationTests: XCTestCase {
    private let home = Place(id: 1, name: "Home", latitude: 37.19, longitude: -122.2, radiusM: 100, costPerKwh: nil)

    func testRecordCoordinatesWinWithoutPlaces() {
        XCTAssertEqual(HistoryLocation.resolve(latitude: 1, longitude: 2, placeName: "Home", places: .idle), .known(latitude: 1, longitude: 2))
        XCTAssertFalse(HistoryLocation.needsPlaces(latitude: 1, longitude: 2, placeName: "Home"))
    }

    func testGeofenceMatchFailureAndUnmatchedAreDistinct() {
        XCTAssertEqual(HistoryLocation.resolve(latitude: nil, longitude: nil, placeName: " home ", places: .loaded([home])),
                       .known(latitude: 37.19, longitude: -122.2))
        XCTAssertEqual(HistoryLocation.resolve(latitude: nil, longitude: nil, placeName: "Work", places: .loaded([home])), .unmapped)
        XCTAssertEqual(HistoryLocation.resolve(latitude: nil, longitude: nil, placeName: "Home", places: .failed("down")),
                       .placesUnavailable("down"))
        XCTAssertEqual(HistoryLocation.resolve(latitude: nil, longitude: nil, placeName: "Home", places: .loading), .pending)
        // Address only: never looked up externally, never pending.
        XCTAssertEqual(HistoryLocation.resolve(latitude: nil, longitude: nil, placeName: nil, places: .loading), .unmapped)
        XCTAssertFalse(HistoryLocation.needsPlaces(latitude: nil, longitude: nil, placeName: nil))
        XCTAssertEqual(HistoryLocation.resolve(latitude: 1, longitude: nil, placeName: nil, places: .idle), .unmapped)

        let summary = HistoryMapSummary([.known(latitude: 0, longitude: 0), .unmapped, .placesUnavailable("x"), .pending])
        XCTAssertEqual(summary.pending, 1)
        XCTAssertEqual(summary.unmapped, 2)
        XCTAssertTrue(summary.placesFailed)
    }

    @MainActor func testPlacesLoadTerminatesOnFailureAndRetries() async {
        let places = HistoryPlaces()
        await places.load(dataSource: PlacesFailingSource(), vehicleID: 1)
        guard case .failed = places.state else { return XCTFail("expected failure, got \(places.state)") }
        await places.retry(dataSource: MockDataSource(), vehicleID: 1)
        guard case .loaded(let list) = places.state else { return XCTFail("expected loaded") }
        XCTAssertFalse(list.isEmpty)
    }

    func testCoordinatesDecodeWhenPresentAndWhenAbsent() throws {
        let decoder = APIDataSource.makeDecoder()
        let base = #""id":1,"start":"2026-10-06T12:00:00Z","end":null,"address":"Palo Alto, CA","placeName":null,"#
        let charge = #"{"# + base + #""energyAddedKwh":null,"energyUsedKwh":null,"startBatteryLevel":null,"endBatteryLevel":null,"durationMin":30,"maxPowerKw":null,"fastCharger":false,"cost":null,"currency":null,"outsideTempAvgC":null"#
        let withCoords = try decoder.decode(ChargeSummary.self, from: Data((charge + #","latitude":37.1,"longitude":-122.2}"#).utf8))
        XCTAssertEqual(withCoords.latitude, 37.1); XCTAssertEqual(withCoords.longitude, -122.2)
        let without = try decoder.decode(ChargeSummary.self, from: Data((charge + "}").utf8))
        XCTAssertNil(without.latitude); XCTAssertNil(without.longitude)
        let nulls = try decoder.decode(ChargeSummary.self, from: Data((charge + #","latitude":null,"longitude":null}"#).utf8))
        XCTAssertNil(nulls.latitude)

        let idle = #"{"# + base + #""durationMin":30,"startBatteryLevel":null,"endBatteryLevel":null,"rangeLostKm":null,"energyLostKwh":null,"sentryMinutes":null,"climateMinutes":null,"asleepMinutes":null"#
        XCTAssertEqual(try decoder.decode(IdleSummary.self, from: Data((idle + #","latitude":1,"longitude":2}"#).utf8)).longitude, 2)
        XCTAssertNil(try decoder.decode(IdleSummary.self, from: Data((idle + "}").utf8)).latitude)
    }
}

final class HistoryRound2Tests: XCTestCase {
    private let home = Place(id: 1, name: "Home", latitude: 37.19, longitude: -122.2, radiusM: 100, costPerKwh: nil)

    private func charge(_ id: Int, place: String? = nil, address: String? = nil,
                        lat: Double? = nil, lon: Double? = nil) -> ChargeSummary {
        ChargeSummary(id: id, start: .init(timeIntervalSince1970: 0), end: nil, address: address, placeName: place,
                      energyAddedKwh: 1, energyUsedKwh: nil, startBatteryLevel: nil, endBatteryLevel: nil,
                      durationMin: 60, maxPowerKw: nil, fastCharger: false, cost: nil, currency: nil,
                      outsideTempAvgC: nil, latitude: lat, longitude: lon)
    }

    // Round 2, finding 1: sessions are grouped by resolved location, never by title.
    func testMapGroupingNeverBorrowsAnotherSessionsCoordinates() {
        let known = charge(1, lat: 37.3, lon: -122.1)
        let unknown = charge(2)
        XCTAssertEqual(known.title, unknown.title, "both read 'Unknown location'")
        let grouping = HistoryMapGrouping([known, unknown]) { $0.location(.loaded([self.home])) }
        XCTAssertEqual(grouping.clusters.count, 1)
        XCTAssertEqual(grouping.clusters[0].items.map(\.id), [1])
        XCTAssertEqual(grouping.summary.unmapped, 1, "the unresolved session is counted, not pinned")
        XCTAssertEqual(grouping.summary.message, "1 session has no coordinates and isn't shown.")
    }

    func testMapGroupingClustersByPositionAndCountsEverySession() {
        let items = [
            charge(1, place: "Home"),                         // geofence match
            charge(2, place: "home "),                        // same geofence
            charge(3, place: "Work", lat: 37.3, lon: -122.1),  // own coordinates
            charge(4, place: "Work", lat: 37.4, lon: -122.0),  // same title, different place
            charge(5, place: "Gym"),                          // no match
            charge(6, address: "Somewhere"),                  // no coordinates
        ]
        let grouping = HistoryMapGrouping(items) { $0.location(.loaded([self.home])) }
        XCTAssertEqual(grouping.clusters.map { $0.items.map(\.id) }, [[1, 2], [3], [4]])
        XCTAssertEqual(grouping.clusters[0].latitude, 37.19)
        XCTAssertEqual(grouping.clusters[0].title(\.title), "Home")
        XCTAssertEqual(grouping.summary.unmapped, 2)
        XCTAssertEqual(grouping.summary.message, "2 sessions have no coordinates and aren't shown.")

        let pending = HistoryMapGrouping(items) { $0.location(.loading) }
        XCTAssertEqual(pending.clusters.map { $0.items.map(\.id) }, [[3], [4]])
        XCTAssertEqual(pending.summary.pending, 3)
        XCTAssertEqual(pending.summary.unmapped, 1)

        let failed = HistoryMapGrouping(items) { $0.location(.failed("down")) }
        XCTAssertTrue(failed.summary.placesFailed)
        XCTAssertEqual(failed.summary.unmapped, 4)
        XCTAssertEqual(failed.summary.message, "Saved places couldn't load, so 4 sessions can't be mapped.")
    }

    func testClusterTitleIsMostCommon() {
        let cluster = HistoryMapCluster(id: "x", latitude: 0, longitude: 0,
                                        items: [charge(1, address: "A"), charge(2, place: "B"), charge(3, place: "B")])
        XCTAssertEqual(cluster.title(\.title), "B")
    }

    // Round 2, finding 2: the map's "Load more" drives the same feed pagination,
    // and the scope stays "partial" until the cursor runs out.
    @MainActor func testMapLoadMoreAdvancesUntilComplete() async {
        let feed = HistoryFeed<IdleSummary>()
        let source = MockDataSource()
        await feed.reload(range: DateRange(from: nil, to: nil), fetch: { r, c in
            try await source.idles(vehicleID: 1, range: r, cursor: c)
        }, showSkeleton: true)
        XCTAssertTrue(feed.hasMore, "mock idles span several pages")
        XCTAssertEqual(HistoryTotalsScope.title(period: "All time", hasMore: feed.hasMore, noun: "sessions"), "Loaded sessions — partial")
        var pages = 1
        while feed.canLoadMore && pages < 50 {
            let before = feed.items.count
            await feed.loadMore()
            XCTAssertGreaterThan(feed.items.count, before)
            pages += 1
        }
        XCTAssertFalse(feed.hasMore)
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(Set(feed.items.map(\.id)).count, feed.items.count)
        XCTAssertEqual(HistoryTotalsScope.title(period: "All time", hasMore: feed.hasMore, noun: "sessions"), "All time")
    }

    // Round 2, finding 3
    func testRangeAddedNeedsTwoDistinctMeasurements() {
        func sample(_ s: Double, _ km: Double?) -> ChargeSample {
            ChargeSample(t: .init(timeIntervalSince1970: s), batteryLevel: nil, powerKw: nil, voltage: nil, currentA: nil, ratedRangeKm: km)
        }
        XCTAssertNil(ChargeMath.rangeAddedKm([]))
        XCTAssertNil(ChargeMath.rangeAddedKm([sample(0, 200)]), "one sample is unknown, not +0")
        XCTAssertNil(ChargeMath.rangeAddedKm([sample(0, 200), sample(60, nil), sample(120, nil)]))
        XCTAssertNil(ChargeMath.rangeAddedKm([sample(0, 200), sample(0, 210)]), "same instant is not two measurements")
        XCTAssertEqual(ChargeMath.rangeAddedKm([sample(0, nil), sample(60, 200), sample(120, nil), sample(180, 330)]), 130)
    }

    // Round 2, finding 4
    func testRegenIsUnknownWithoutPowerAndPartialWhenSparse() throws {
        func point(_ s: Double, _ kw: Double?) -> DrivePoint {
            DrivePoint(t: .init(timeIntervalSince1970: s), latitude: 0, longitude: 0, speedKph: 50, powerKw: kw,
                       elevationM: nil, batteryLevel: nil)
        }
        XCTAssertNil(RegenEstimate([]))
        XCTAssertNil(RegenEstimate([point(0, -30)]), "no interval")
        XCTAssertNil(RegenEstimate([point(0, nil), point(3600, nil), point(7200, -10)]), "missing power is not 0 kWh")

        let full = try XCTUnwrap(RegenEstimate([point(0, -36), point(100, 20), point(200, nil)]))
        XCTAssertEqual(full.kwh, 1, accuracy: 1e-9)
        XCTAssertEqual(full.measuredIntervals, 2)
        XCTAssertEqual(full.isPartial, false)
        XCTAssertNil(full.note)

        let partial = try XCTUnwrap(RegenEstimate([point(0, -36), point(100, nil), point(200, 5)]))
        XCTAssertEqual(partial.measuredIntervals, 1)
        XCTAssertEqual(partial.totalIntervals, 2)
        XCTAssertEqual(partial.isPartial, true)
        XCTAssertEqual(partial.note, "Regen from the 1 of 2 intervals with recorded power")

        let noRegen = RegenEstimate([point(0, 20), point(60, 25)])
        XCTAssertEqual(noRegen?.kwh, 0, "measured with no regen is a real 0")
    }
}
