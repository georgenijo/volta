import Foundation

/// Synthetic "Friday" data for previews, placeholders and the widget gallery.
/// Mirrors ios/Volta/Core/MockDataSource.swift so widgets match app previews.
extension WidgetSnapshot {
    static func fixture(now: Date = .now) -> WidgetSnapshot {
        WidgetSnapshot(
            vehicleId: 1, vehicleName: "Friday", state: .online,
            updatedAt: now.addingTimeInterval(-4 * 60), writtenAt: now,
            batteryLevel: 72, chargeLimit: 80, estRangeKm: 328, ratedRangeKm: 354,
            chargingState: .disconnected, chargerPowerKw: nil, minutesToFull: nil,
            insideTempC: 21, outsideTempC: 16, climateOn: false, locked: true, sentryMode: true,
            placeName: "Home",
            today: Today(distanceKm: 41.3, driveCount: 2, chargeCount: 0, energyUsedKwh: 6.8,
                         efficiencyWhPerKm: 164, energyAddedKwh: 0),
            todayDay: Calendar.current.startOfDay(for: now),
            todayDayEnd: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)),
            todayZone: TimeZone.current.identifier,
            timeline: fixtureTimeline(now: now))
    }

    static func fixtureCharging(now: Date = .now) -> WidgetSnapshot {
        var s = fixture(now: now)
        s.state = .charging; s.chargingState = .charging
        s.batteryLevel = 58; s.estRangeKm = 262; s.ratedRangeKm = 285
        s.chargerPowerKw = 7.7; s.minutesToFull = 94; s.sentryMode = false
        s.today?.chargeCount = 1; s.today?.energyAddedKwh = 11.2
        return s
    }

    static func fixtureDriving(now: Date = .now) -> WidgetSnapshot {
        var s = fixture(now: now)
        s.state = .driving; s.locked = true; s.sentryMode = false; s.climateOn = true
        s.batteryLevel = 64; s.estRangeKm = 291; s.placeName = "I-95 N"
        s.updatedAt = now.addingTimeInterval(-30)
        return s
    }

    static func fixtureLowStale(now: Date = .now) -> WidgetSnapshot {
        var s = fixture(now: now)
        s.state = .asleep; s.sentryMode = false; s.locked = false
        s.batteryLevel = 14; s.estRangeKm = 58; s.ratedRangeKm = 66
        s.insideTempC = 4; s.outsideTempC = 1
        s.updatedAt = now.addingTimeInterval(-3 * 3600)
        s.today = Today(distanceKm: 0, driveCount: 0, chargeCount: 0, energyUsedKwh: nil,
                        efficiencyWhPerKm: nil, energyAddedKwh: nil)
        s.distanceUnit = .kilometers; s.temperatureUnit = .celsius
        return s
    }

    /// Charging snapshot two hours old with an unknown limit: widgets must show it as stale.
    static func fixtureChargingStale(now: Date = .now) -> WidgetSnapshot {
        var s = fixtureCharging(now: now)
        s.chargeLimit = nil
        s.updatedAt = now.addingTimeInterval(-2 * 3600)
        return s
    }

    static func fixtureTimeline(now: Date) -> [Segment] {
        // (kind, hours ago start, hours ago end), oldest first.
        let plan: [(SegmentKind, Double, Double)] = [
            (.asleep, 48, 38.5), (.drive, 38.5, 37.8), (.idle, 37.8, 33), (.drive, 33, 32.4),
            (.charge, 32.4, 29.2), (.asleep, 29.2, 14.5), (.drive, 14.5, 14), (.idle, 14, 10.4),
            (.drive, 10.4, 9.7), (.asleep, 9.7, 2.6), (.drive, 2.6, 2.1), (.idle, 2.1, 0),
        ]
        return plan.map { Segment(kind: $0.0, start: now.addingTimeInterval(-$0.1 * 3600),
                                  end: now.addingTimeInterval(-$0.2 * 3600)) }
    }
}

extension ChargingActivityAttributes {
    static let fixture = ChargingActivityAttributes(
        vehicleId: 1, chargeId: 4211, vehicleName: "Friday", placeName: "Home",
        startedAt: .now.addingTimeInterval(-52 * 60), startBatteryLevel: 49, fastCharger: false, usesMiles: true)
    static let fixtureSupercharger = ChargingActivityAttributes(
        vehicleId: 1, chargeId: 4212, vehicleName: "Friday", placeName: "Mountain View Supercharger",
        startedAt: .now.addingTimeInterval(-11 * 60), startBatteryLevel: 22, fastCharger: true, usesMiles: true)
}

extension ChargingActivityAttributes.ContentState {
    static let early = Self(batteryLevel: 53, chargeLimit: 80, chargerPowerKw: 7.7,
                            fullAt: .now.addingTimeInterval(128 * 60), energyAddedKwh: 3.1,
                            rangeKm: 240, updatedAt: .now)
    static let midway = Self(batteryLevel: 66, chargeLimit: 80, chargerPowerKw: 7.6,
                             fullAt: .now.addingTimeInterval(71 * 60), energyAddedKwh: 13.0,
                             rangeKm: 298, updatedAt: .now)
    /// Limit, ETA and energy unknown: rendered as "—", never guessed.
    static let unknownLimit = Self(batteryLevel: 61, chargeLimit: nil, chargerPowerKw: 7.4,
                                   fullAt: nil, energyAddedKwh: nil, rangeKm: nil, updatedAt: .now)
    static let supercharging = Self(batteryLevel: 47, chargeLimit: 80, chargerPowerKw: 168,
                                    fullAt: .now.addingTimeInterval(16 * 60), energyAddedKwh: 19.4,
                                    rangeKm: 213, updatedAt: .now)
    static let complete = Self(batteryLevel: 80, chargeLimit: 80, chargerPowerKw: nil, fullAt: nil,
                               energyAddedKwh: 23.4, rangeKm: 362, phase: .completed,
                               updatedAt: .now, endedAt: .now.addingTimeInterval(-2 * 60))
    static let stopped = Self(batteryLevel: 71, chargeLimit: 80, chargerPowerKw: nil, fullAt: nil,
                              energyAddedKwh: 15.8, rangeKm: 322, phase: .stopped,
                              updatedAt: .now, endedAt: .now.addingTimeInterval(-60))
}

extension DrivingActivityAttributes {
    static let fixture = DrivingActivityAttributes(
        vehicleId: 1, driveId: 9876, vehicleName: "Friday", startedAt: .now.addingTimeInterval(-23 * 60),
        startAddress: "Palo Alto, CA", startBatteryLevel: 72, usesMiles: true)
}

extension DrivingActivityAttributes.ContentState {
    static let cruising = Self(batteryLevel: 66, rangeKm: 301, distanceKm: 27.4,
                               energyUsedKwh: 4.6, updatedAt: .now)
    static let city = Self(batteryLevel: 70, rangeKm: 318, distanceKm: 6.2,
                           energyUsedKwh: 1.1, updatedAt: .now)
    /// The open drive could not be fetched: distance and energy stay "—".
    static let unknownDistance = Self(batteryLevel: 69, rangeKm: 310, distanceKm: nil,
                                      energyUsedKwh: nil, updatedAt: .now)
    static let ended = Self(batteryLevel: 63, rangeKm: 288, distanceKm: 31.9, energyUsedKwh: 5.4,
                            phase: .ended, updatedAt: .now, endedAt: .now.addingTimeInterval(-60))
}
