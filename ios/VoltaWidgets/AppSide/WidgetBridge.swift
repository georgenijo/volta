import Foundation
import WidgetKit

// APP TARGET ONLY. Maps ios/Volta/Core models (VehicleStatus, ActivitySummary,
// TimelineSegment, UnitPreferences) to the widget snapshot. The extension does
// not compile this file. See WidgetSync.swift for when it is written.

extension WidgetSnapshot {
    /// Builds the snapshot for one status refresh.
    ///
    /// Unknown values stay nil. `summary` / `timeline` are nil when this refresh
    /// did not load them (or the load failed); the values from `previous` are
    /// kept if it describes the same vehicle, otherwise they stay unknown.
    /// Previous "today" totals are kept only within the same reporting day
    /// (`ReportingDay`): after it ends they become unknown rather than
    /// yesterday's numbers.
    ///
    /// `summaryRequestedAt`/`summaryRequestedZone` are when and in which device
    /// zone the `/summary?range=today` request started (nil: `now`,
    /// `deviceZone`). Totals are stamped with their reporting day
    /// (`TodaySummary.day`: the server-reported period, or the UTC day of the
    /// request on older servers). If that day isn't current at `now` in
    /// `deviceZone` (it ended, or the device changed zone) the totals are
    /// dropped and today becomes unknown.
    init(status: VehicleStatus, vehicleName: String, summary: ActivitySummary?, summaryRequestedAt: Date? = nil,
         summaryRequestedZone: String? = nil, timeline: [TimelineSegment]?,
         units: UnitPreferences = .default, now: Date = .now, deviceZone: String = TimeZone.current.identifier,
         previous: WidgetSnapshot? = nil) {
        let sameVehicle = previous?.vehicleId == status.vehicleId ? previous : nil
        let cutoff = now.addingTimeInterval(-48 * 3600)
        let today: Today?
        let todayDay: ReportingDay.Day?
        if let summary {
            let day = TodaySummary(summary: summary, requestedAt: summaryRequestedAt ?? now,
                                   requestedZone: summaryRequestedZone ?? deviceZone).day
            if day.isCurrent(at: now, deviceZone: deviceZone) {
                today = Today(distanceKm: summary.distanceKm, driveCount: summary.driveCount,
                              chargeCount: summary.chargeCount, energyUsedKwh: summary.energyUsedKwh,
                              efficiencyWhPerKm: summary.efficiencyWhPerKm, energyAddedKwh: summary.energyAddedKwh)
                todayDay = day
            } else {
                // The day ended (or the zone changed) before publishing: not today's.
                today = nil
                todayDay = nil
            }
        } else if let kept = sameVehicle?.todayTotals(at: now, deviceZone: deviceZone) {
            today = kept
            todayDay = sameVehicle?.todayReportingDay
        } else {
            today = nil
            todayDay = nil
        }
        let segments = timeline.map { segments in
            segments
                .filter { $0.end > cutoff }
                .map { Segment(kind: SegmentKind(rawValue: $0.kind.rawValue) ?? .idle, start: max($0.start, cutoff), end: $0.end) }
                .sorted { $0.start < $1.start }
        } ?? sameVehicle?.timeline.filter { $0.end > cutoff } ?? []
        self.init(
            vehicleId: status.vehicleId,
            vehicleName: vehicleName,
            state: State(rawValue: status.state.rawValue) ?? .online,
            updatedAt: status.updatedAt,
            writtenAt: now,
            batteryLevel: status.batteryLevel,
            chargeLimit: status.chargeLimit,
            estRangeKm: status.estRangeKm,
            ratedRangeKm: status.ratedRangeKm,
            chargingState: status.chargingState.flatMap { Charging(rawValue: $0.rawValue) },
            chargerPowerKw: status.chargerPowerKw,
            minutesToFull: status.minutesToFull,
            insideTempC: status.insideTempC,
            outsideTempC: status.outsideTempC,
            climateOn: status.climateOn,
            locked: status.locked,
            sentryMode: status.sentryMode,
            placeName: status.location?.placeName ?? status.location?.address,
            today: today,
            todayDay: todayDay?.interval.start,
            todayDayEnd: todayDay?.interval.end,
            todayZone: todayDay?.zone,
            timeline: segments,
            distanceUnit: units.distance == .miles ? .miles : .kilometers,
            temperatureUnit: units.temperature == .fahrenheit ? .fahrenheit : .celsius
        )
    }
}

extension WidgetSnapshotStore {
    /// Deletes the snapshot and reloads every widget so they show the empty state.
    @MainActor
    static func reset() {
        clear()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
