import XCTest
@testable import Volta

@MainActor final class MockAndSettingsTests: XCTestCase {
    func testPopulatedPaginationDetailsAndRanges() async throws {
        let now = Date(timeIntervalSince1970: 1_791_374_400)
        let source = MockDataSource(now: now)
        let vehicles = try await source.vehicles()
        XCTAssertEqual(vehicles.first?.name, "Friday")
        let first = try await source.drives(vehicleID: 1, range: .init(), cursor: nil)
        let second = try await source.drives(vehicleID: 1, range: .init(), cursor: first.nextCursor)
        XCTAssertEqual(first.items.count + second.items.count, 60)
        XCTAssertTrue(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
        XCTAssertNil(second.nextCursor)
        XCTAssertTrue((first.items + second.items).allSatisfy { ($0.end ?? now) <= now })
        let drive = try await source.drive(id: first.items[0].id)
        XCTAssertFalse(drive.path.isEmpty)
        let charges = try await source.charges(vehicleID: 1, range: .init(), cursor: nil)
        XCTAssertTrue(charges.items.contains { $0.fastCharger }); XCTAssertTrue(charges.items.contains { !$0.fastCharger })
        let charge = try await source.charge(id: charges.items[0].id)
        XCTAssertFalse(charge.samples.isEmpty)
        let filtered = try await source.drives(vehicleID: 1, range: .init(from: now.addingTimeInterval(-86400), to: now), cursor: nil)
        XCTAssertEqual(filtered.items.count, 2)
        let battery = try await source.battery(vehicleID: 1)
        XCTAssertEqual(battery.history.count, 25)
        XCTAssertGreaterThan(battery.history.last!.date.timeIntervalSince(battery.history.first!.date), 700 * 86400)
        let timeline = try await source.timeline(vehicleID: 1, hours: 48)
        let ordered = timeline.sorted { $0.start < $1.start }
        XCTAssertEqual(ordered.first?.start, now.addingTimeInterval(-48 * 3600))
        XCTAssertEqual(ordered.last?.end, now)
        for (a, b) in zip(ordered, ordered.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        do { _ = try await source.status(vehicleID: 999); XCTFail() } catch { XCTAssertEqual(error as? VoltaError, .notFound) }
    }
    func testDemoSummaryReportsALocalDayPeriod() async throws {
        let now = Date(timeIntervalSince1970: 1_791_330_900)  // 2026-10-06T23:55:00Z
        let today = try await MockDataSource(now: now).summary(vehicleID: 1, range: .today)
        XCTAssertEqual(today.periodStart, Calendar.current.startOfDay(for: now))
        XCTAssertEqual(today.periodEnd, now)
        XCTAssertEqual(today.timeZone, TimeZone.current.identifier)
        XCTAssertTrue(TodaySummary(summary: today, requestedAt: now).day.isCurrent(at: now))
        let week = try await MockDataSource(now: now).summary(vehicleID: 1, range: .sevenDays)
        XCTAssertEqual(week.periodStart, now.addingTimeInterval(-168 * 3600))
    }
    func testEmptyListsAndNullableHealth() async throws {
        let source = MockDataSource(empty: true)
        let drives = try await source.drives(vehicleID: 1, range: .init(), cursor: nil)
        let charges = try await source.charges(vehicleID: 1, range: .init(), cursor: nil)
        let idles = try await source.idles(vehicleID: 1, range: .init(), cursor: nil)
        let battery = try await source.battery(vehicleID: 1)
        let timeline = try await source.timeline(vehicleID: 1, hours: 48)
        let mileage = try await source.mileage(vehicleID: 1, bucket: .month)
        let firmware = try await source.firmware(vehicleID: 1)
        let places = try await source.places(vehicleID: 1)
        XCTAssertTrue(drives.items.isEmpty && charges.items.isEmpty && idles.items.isEmpty)
        XCTAssertTrue(battery.history.isEmpty && timeline.isEmpty && mileage.isEmpty && firmware.isEmpty && places.isEmpty)
        XCTAssertNil(battery.healthPercent)
        let summary = try await source.summary(vehicleID: 1, range: .thirtyDays)
        XCTAssertEqual(summary.driveCount, 0); XCTAssertNil(summary.efficiencyWhPerKm)
    }
    func testUnitConversionsAndUnknowns() throws {
        let units = UnitPreferences()
        XCTAssertEqual(units.distanceValue(km: 1.609344), 1, accuracy: 0.000001)
        XCTAssertEqual(units.temperatureValue(celsius: 0), 32)
        XCTAssertEqual(units.efficiencyValue(whPerKm: 100), 160.9344, accuracy: 0.0001)
        XCTAssertEqual(VoltaFormat.distance(nil), "—"); XCTAssertEqual(VoltaFormat.energy(nil), "—")
        XCTAssertEqual(VoltaFormat.duration(minutes: 90), "1h 30m")
        let metric = UnitPreferences(distance: .kilometers, temperature: .celsius, currency: "EUR")
        XCTAssertEqual(metric.distanceValue(km: 10), 10)
        XCTAssertEqual(metric.temperatureValue(celsius: 10), 10)
        XCTAssertEqual(try JSONDecoder().decode(UnitPreferences.self, from: JSONEncoder().encode(metric)), metric)
    }
    func testSettingsPersistAndDemoRestores() async throws {
        let suite = "VoltaTests.\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = UserSettings(defaults: defaults)
        settings.units = .init(distance: .kilometers, temperature: .celsius, currency: "EUR")
        settings.serverURL = "https://volta.example"; settings.selectedVehicleID = 3; settings.appLockEnabled = true
        let restored = UserSettings(defaults: defaults)
        XCTAssertEqual(restored.units, settings.units); XCTAssertEqual(restored.serverURL, settings.serverURL)
        XCTAssertEqual(restored.selectedVehicleID, 3); XCTAssertTrue(restored.appLockEnabled)
        restored.appLockEnabled = false
        let store = KeychainTokenStore(service: suite)
        defer { try? store.delete() }
        let model = AppModel(settings: restored, tokenStore: store)
        model.tryDemoMode(); await model.loadVehicles()
        XCTAssertEqual(model.pairingState, .demo); XCTAssertEqual(model.selectedVehicle?.name, "Friday")
        let relaunched = AppModel(settings: UserSettings(defaults: defaults), tokenStore: store)
        XCTAssertTrue(relaunched.isDemoMode)
        model.unpair(); XCTAssertFalse(model.isPaired); XCTAssertFalse(restored.demoMode)
    }
    func testKeychainRoundTrip() throws {
        let store = KeychainTokenStore(service: "VoltaTests.\(UUID())")
        defer { try? store.delete() }
        do {
            try store.delete(); XCTAssertNil(try store.load())
            try store.save("synthetic-first"); XCTAssertEqual(try store.load(), "synthetic-first")
            try store.save("synthetic-second"); XCTAssertEqual(try store.load(), "synthetic-second")
            try store.delete(); XCTAssertNil(try store.load())
        } catch let error as KeychainTokenStore.StoreError where error.status == -34018 {
            throw XCTSkip("Simulator test host lacks Keychain entitlement: \(error.status)")
        }
    }
}
