import Foundation

/// Everything the trip screen derives from one loaded drive, computed once per
/// load (and per unit change) so scrubbing and replay don't recompute it.
struct TripSnapshot {
    let detail: DriveDetail
    let timeline: TripTimeline
    let routes: [TripMapMode: TripRoute]
    let battery: TripChartSeries
    let power: TripChartSeries
    let speed: TripChartSeries
    let elevation: TripChartSeries
    let telemetryBattery: TelemetryMetricSeries
    let energyRemaining: TelemetryMetricSeries
    let batteryTempMin: TelemetryMetricSeries
    let batteryTempMax: TelemetryMetricSeries
    let insideTemp: TelemetryMetricSeries
    let outsideTemp: TelemetryMetricSeries
    let longitudinalAcceleration: TelemetryMetricSeries
    let lateralAcceleration: TelemetryMetricSeries
    let usesFleetTelemetry: Bool
    let usesTelemetryBattery: Bool
    let usesTelemetryPower: Bool
    let usesTelemetrySpeed: Bool
    let usesTelemetryElevation: Bool
    let telemetryTruncated: Bool
    let regen: TripEstimate
    let maxSpeed: TripMetric
    let descent: TripMetric
    let score: SmoothnessScore.Result

    init(_ detail: DriveDetail, units: UnitPreferences) {
        self.detail = detail
        let s = detail.summary
        let end = s.end ?? s.start.addingTimeInterval(s.durationMin * 60)
        let legacy = TripTimeline(path: detail.path, start: s.start, end: end)
        let telemetryPath = detail.telemetry?.drivePath() ?? []
        let legacyMap = RecordedMetricCoverage.values(in: legacy) { _ in 1 }
        usesFleetTelemetry = telemetryPath.count >= 2
            && detail.telemetry?.shouldPrefer(metric: "latitude", over: legacyMap) == true
            && detail.telemetry?.shouldPrefer(metric: "longitude", over: legacyMap) == true
        telemetryTruncated = detail.telemetry?.truncated == true
        let timeline = TripTimeline(path: usesFleetTelemetry ? telemetryPath : detail.path, start: s.start, end: end)
        self.timeline = timeline
        routes = Dictionary(uniqueKeysWithValues: TripMapMode.allCases.map { ($0, TripRoute(timeline, mode: $0)) })
        let feet = units.distance == .miles
        let telemetryBatteryTimeline = Self.metricTimeline(detail.telemetry, field: "BatteryLevel", start: s.start, end: end,
                                                           value: { $0.batteryLevel }) { $0.batteryLevel = Int($1.rounded()) }
        let telemetryPowerTimeline = Self.metricTimeline(detail.telemetry, field: "Power", start: s.start, end: end,
                                                         value: { $0.powerKw }) { $0.powerKw = $1 }
        let telemetrySpeedTimeline = Self.metricTimeline(detail.telemetry, field: "VehicleSpeed", start: s.start, end: end,
                                                         value: { $0.speedKph }) { $0.speedKph = $1 }
        let telemetryElevationTimeline = Self.metricTimeline(detail.telemetry, field: nil, start: s.start, end: end,
                                                             value: { $0.elevationM }) { $0.elevationM = $1 }
        usesTelemetryBattery = detail.telemetry?.shouldPrefer(
            metric: "batteryLevel", over: .values(in: legacy) { $0.batteryLevel.map(Double.init) }) == true
        usesTelemetryPower = detail.telemetry?.shouldPrefer(
            metric: "powerKw", over: .values(in: legacy) { $0.powerKw }) == true
        usesTelemetrySpeed = detail.telemetry?.shouldPrefer(
            metric: "speedKph", over: .values(in: legacy) { $0.speedKph }) == true
        usesTelemetryElevation = detail.telemetry?.shouldPrefer(
            metric: "elevationM", over: .values(in: legacy) { $0.elevationM }) == true
        let batteryTimeline = usesTelemetryBattery ? telemetryBatteryTimeline : legacy
        let powerTimeline = usesTelemetryPower ? telemetryPowerTimeline : legacy
        let speedTimeline = usesTelemetrySpeed ? telemetrySpeedTimeline : legacy
        let elevationTimeline = usesTelemetryElevation ? telemetryElevationTimeline : legacy
        battery = TripChartSeries(batteryTimeline) { $0.batteryLevel.map(Double.init) }
        power = TripChartSeries(powerTimeline) { $0.powerKw }
        speed = TripChartSeries(speedTimeline) { $0.speedKph.map { units.distanceValue(km: $0) } }
        elevation = TripChartSeries(elevationTimeline) { $0.elevationM.map { feet ? $0 * 3.28084 : $0 } }
        telemetryBattery = TelemetryMetricSeries(detail.telemetry, field: "BatteryLevel") { $0.batteryLevel }
        energyRemaining = TelemetryMetricSeries(detail.telemetry, field: "EnergyRemaining") { $0.energyRemainingKwh }
        batteryTempMin = TelemetryMetricSeries(detail.telemetry, field: "ModuleTempMin") { $0.batteryTempMinC.map { units.temperatureValue(celsius: $0) } }
        batteryTempMax = TelemetryMetricSeries(detail.telemetry, field: "ModuleTempMax") { $0.batteryTempMaxC.map { units.temperatureValue(celsius: $0) } }
        insideTemp = TelemetryMetricSeries(detail.telemetry, field: "InsideTemp") { $0.insideTempC.map { units.temperatureValue(celsius: $0) } }
        outsideTemp = TelemetryMetricSeries(detail.telemetry, field: "OutsideTemp") { $0.outsideTempC.map { units.temperatureValue(celsius: $0) } }
        longitudinalAcceleration = TelemetryMetricSeries(detail.telemetry, field: "LongitudinalAcceleration") { $0.longitudinalAccelerationMps2 }
        lateralAcceleration = TelemetryMetricSeries(detail.telemetry, field: "LateralAcceleration") { $0.lateralAccelerationMps2 }
        // Charts and max speed can use a whole-session downsample that is still
        // denser than legacy. Interval-derived metrics cannot: downsampling
        // changes acceleration, integration and elevation extrema between rows.
        let powerForRegen = usesTelemetryPower && detail.telemetry?.coverage?.metrics["powerKw"]?.downsampled != true
            ? powerTimeline : legacy
        let telemetrySpeedIsFull = usesTelemetrySpeed
            && detail.telemetry?.coverage?.metrics["speedKph"]?.downsampled != true
        let telemetryPowerIsFull = usesTelemetryPower
            && detail.telemetry?.coverage?.metrics["powerKw"]?.downsampled != true
        let combinedTelemetryScore = Self.scoreTimeline(detail.telemetry, start: s.start, end: end)
        let telemetryScoreKeepsPowerCoverage = Self.coTimedPowerCoverage(combinedTelemetryScore)
            >= Self.coTimedPowerCoverage(legacy)
        let legacyScore = SmoothnessScore.evaluate(legacy)
        let candidateScore = SmoothnessScore.evaluate(combinedTelemetryScore)
        let telemetryScoreKeepsPowerPart = !Self.hasPowerPart(legacyScore) || Self.hasPowerPart(candidateScore)
        let useTelemetryScore = telemetrySpeedIsFull && telemetryPowerIsFull
            && telemetryScoreKeepsPowerCoverage && telemetryScoreKeepsPowerPart
        let elevationForDescent = usesTelemetryElevation && detail.telemetry?.coverage?.metrics["elevationM"]?.downsampled != true
            ? elevationTimeline : legacy
        regen = TripAnalysis.regen(powerForRegen)
        maxSpeed = TripAnalysis.maxSpeed(summary: s.maxSpeedKph, timeline: speedTimeline)
        descent = TripAnalysis.descent(elevationForDescent)
        score = useTelemetryScore ? candidateScore : legacyScore
    }

    /// Builds a signal-only timeline without inventing positions. Rows for
    /// other telemetry fields are omitted; explicit invalidity and receiver
    /// gaps are retained as segment boundaries by TelemetryMetricSeries.
    private static func metricTimeline(_ telemetry: FleetTelemetrySeries?, field: String?, start: Date, end: Date,
                                       value: (FleetTelemetrySample) -> Double?,
                                       assign: (inout DrivePoint, Double) -> Void) -> TripTimeline {
        let series = TelemetryMetricSeries(telemetry, field: field, value: value)
        var previousSegment: Int?
        let points = series.points.map { sample -> DrivePoint in
            var point = DrivePoint(t: sample.t, latitude: 0, longitude: 0, speedKph: nil, powerKw: nil,
                                   elevationM: nil, batteryLevel: nil,
                                   routeBreakBefore: previousSegment.map { $0 != sample.segment } ?? false)
            assign(&point, sample.value)
            previousSegment = sample.segment
            return point
        }
        return TripTimeline(path: points, start: start, end: end)
    }

    /// Smoothness v1 evaluates speed and, when sufficiently co-timed, power.
    /// Combine only exact timestamps from the two independently gated full
    /// telemetry series. Missing power stays nil; a power gap drops the first
    /// value after its boundary so no interval bridges explicit invalidity.
    private static func scoreTimeline(_ telemetry: FleetTelemetrySeries?, start: Date, end: Date) -> TripTimeline {
        let speed = TelemetryMetricSeries(telemetry, field: "VehicleSpeed") { $0.speedKph }
        let power = TelemetryMetricSeries(telemetry, field: "Power") { $0.powerKw }
        var powerByTime: [Date: TelemetryMetricSeries.Point] = [:]
        for point in power.points where powerByTime[point.t] == nil { powerByTime[point.t] = point }
        var priorSpeedSegment: Int?
        var priorPowerSegment: Int?
        let points = speed.points.map { sample -> DrivePoint in
            let powerPoint = powerByTime[sample.t]
            let crossesPowerBoundary = powerPoint.flatMap { point in
                priorPowerSegment.map { $0 != point.segment }
            } ?? false
            let point = DrivePoint(t: sample.t, latitude: 0, longitude: 0, speedKph: sample.value,
                                   powerKw: crossesPowerBoundary ? nil : powerPoint?.value,
                                   elevationM: nil, batteryLevel: nil,
                                   routeBreakBefore: priorSpeedSegment.map { $0 != sample.segment } ?? false)
            priorSpeedSegment = sample.segment
            if let powerPoint { priorPowerSegment = powerPoint.segment }
            return point
        }
        return TripTimeline(path: points, start: start, end: end)
    }

    private static func coTimedPowerCoverage(_ timeline: TripTimeline) -> TimeInterval {
        TripSignal(timeline) { point in
            guard point.speedKph?.isFinite == true else { return nil }
            return point.powerKw
        }.coveredSeconds
    }

    private static func hasPowerPart(_ result: SmoothnessScore.Result) -> Bool {
        guard case .score(let score) = result else { return false }
        return score.parts.contains { $0.name == "Power" }
    }
}
