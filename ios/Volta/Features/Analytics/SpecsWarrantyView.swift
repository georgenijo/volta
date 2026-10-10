import SwiftUI

/// Vehicle facts, odometer, and Tesla's standard warranty coverage measured
/// against a purchase date stored only on this device.
struct SpecsWarrantyView: View {
    struct Coverage: Identifiable {
        var name: String
        var symbol: String
        var years: Double
        var miles: Double
        var id: String { name }
    }

    /// Tesla's standard US coverage for Model 3/Y Long Range. Edit if your car differs.
    static let coverages = [
        Coverage(name: "Basic Vehicle", symbol: "car", years: 4, miles: 50_000),
        Coverage(name: "Battery & Drive Unit", symbol: "battery.100percent.bolt", years: 8, miles: 120_000),
    ]

    struct Snapshot: Sendable {
        var vehicle: Vehicle?
        var odometerKm: Double?
    }

    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<Snapshot> = .loading
    @State private var editingDate = false
    /// Local only, never sent to the server. Persisted per server + vehicle; launch demo keeps it in memory.
    @State private var purchaseDate: Date?

    /// UserDefaults key scoped to the paired server (or demo) and vehicle. nil = don't persist (launch demo).
    nonisolated static func purchaseDateKey(serverURL: String, isDemo: Bool, isLaunchDemo: Bool, vehicleID: Int) -> String? {
        if isLaunchDemo { return nil }
        let scope = isDemo ? "demo" : AnalyticsMath.serverScope(serverURL)
        return "volta.warranty.purchaseDate.\(scope).\(vehicleID)"
    }

    private var storageKey: String? {
        Self.purchaseDateKey(serverURL: model.settings.serverURL, isDemo: model.isDemoMode, isLaunchDemo: model.isLaunchDemo, vehicleID: vehicleID)
    }

    private func setPurchaseDate(_ date: Date?) {
        purchaseDate = date
        guard let storageKey else { return }
        if let date { UserDefaults.standard.set(date.timeIntervalSince1970, forKey: storageKey) }
        else { UserDefaults.standard.removeObject(forKey: storageKey) }
    }

    var body: some View {
        ScrollView {
            LoadableContent(state: state, retry: load) { snapshot in
                VStack(alignment: .leading, spacing: AnalyticsStyle.sectionGap) {
                    if let vehicle = snapshot.vehicle {
                        hero(vehicle, odometer: snapshot.odometerKm)
                        specs(vehicle)
                    } else {
                        EmptyState(systemImage: "car", title: "No vehicle", message: "TeslaMate hasn't reported a vehicle yet.")
                            .padding(.vertical, 40)
                    }
                    warranty(odometerKm: snapshot.odometerKm)
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.specs")
        .voltaArrivalScope(isReady: state.isSettled)
        .screenKitPage("Specs & Warranty")
        .task(id: vehicleID) { await load() }
        .task(id: storageKey) {
            let raw = storageKey.map { UserDefaults.standard.double(forKey: $0) } ?? 0
            purchaseDate = raw > 0 ? Date(timeIntervalSince1970: raw) : nil
        }
        .sheet(isPresented: $editingDate) { purchaseSheet }
    }

    private func hero(_ v: Vehicle, odometer: Double?) -> some View {
        let remaining = Self.coverages.map { c in odometer.map { max(0, c.miles * 1.609344 - $0) } }
        let yearsOwned = purchaseDate.map { Date.now.timeIntervalSince($0) / (365.25 * 86_400) }
        return VStack(alignment: .leading, spacing: 0) {
            AnalyticsHero(eyebrow: [v.name, v.model].compactMap { $0 }.joined(separator: " · ") + " · Odometer",
                          value: odometer.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—",
                          unit: units.distanceUnit, identifier: "screen.specs")
            AnalyticsStatStrip(items: [
                (remaining[0].map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—", "Basic left"),
                (remaining[1].map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—", "Battery left"),
                (yearsOwned.map { "\(VoltaFormat.number($0, digits: 1)) yr" } ?? "—", "Owned"),
                (odometer.map { "\(Int((min($0 / (Self.coverages[0].miles * 1.609344), 1) * 100).rounded()))%" } ?? "—", "Basic used"),
            ])
            .padding(.top, 22)
        }
    }

    private func specs(_ v: Vehicle) -> some View {
        let rows: [(String, String?)] = [
            ("Model", v.model), ("Trim", v.trim), ("Color", v.exteriorColor),
            ("VIN", v.vinSuffix.map { "••••\($0)" }), ("Software", v.firmware),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            AnalyticsSectionHeader("Specs")
            AnalyticsGroup {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    AnalyticsRow(title: row.0, value: row.1 ?? "—", valueColor: AnalyticsStyle.secondary, showsDivider: index < rows.count - 1)
                }
            }
        }
    }

    @ViewBuilder
    private func warranty(odometerKm: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AnalyticsSectionHeader("Warranty", trailing: "Whichever comes first")
            Button { editingDate = true } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Purchase date").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        Text(model.isLaunchDemo ? "Not saved in launch demo" : "Stored on this device only")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(AnalyticsStyle.tertiary)
                    }
                    Spacer(minLength: 8)
                    Text(purchaseDate?.formatted(date: .abbreviated, time: .omitted) ?? "Set")
                        .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(purchaseDate == nil ? AnalyticsStyle.blue : AnalyticsStyle.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(AnalyticsStyle.tertiary)
                }
                .padding(.horizontal, 18).padding(.vertical, 15)
                .contentShape(Rectangle())
                .voltaCardBackground()
            }
            .buttonStyle(VoltaPressStyle())

            VStack(spacing: AnalyticsStyle.cardGap) {
                ForEach(Self.coverages) { coverage in
                    coverageCard(coverage, odometerKm: odometerKm)
                }
            }
            .padding(.top, AnalyticsStyle.cardGap)
            AnalyticsFootnote("Tesla's standard US limited warranty terms. Coverage ends at whichever limit comes first.")
                .padding(.top, 12)
        }
    }

    private func coverageCard(_ c: Coverage, odometerKm: Double?) -> some View {
        let milesUsed = odometerKm.map { $0 / 1.609344 }
        let mileFraction = milesUsed.map { $0 / c.miles }
        let yearsUsed = purchaseDate.map { Date.now.timeIntervalSince($0) / (365.25 * 86_400) }
        let yearFraction = yearsUsed.map { $0 / c.years }
        let limitDistanceKm = c.miles * 1.609344
        let status = AnalyticsMath.coverageStatus(purchaseDate: purchaseDate, odometerKm: odometerKm, years: c.years, limitKm: limitDistanceKm)
        let statusTint = status == .expired ? AnalyticsStyle.red : status == .active ? AnalyticsStyle.mint : AnalyticsStyle.tertiary

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: c.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(AnalyticsStyle.mint)
                Text(c.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(statusTint).frame(width: 6, height: 6).shadow(color: statusTint.opacity(0.8), radius: 4)
                    Text(status == .expired ? "EXPIRED" : status == .active ? "ACTIVE" : "UNKNOWN")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(status == .unknown ? AnalyticsStyle.tertiary : statusTint)
                }
            }
            Rectangle().fill(AnalyticsStyle.hairline).frame(height: 1)
            progress(label: "Distance",
                     detail: "\(units.formatDistance(odometerKm, fractionDigits: 0)) of \(units.formatDistance(limitDistanceKm, fractionDigits: 0))",
                     fraction: mileFraction)
            progress(label: "Time",
                     detail: yearsUsed.map { "\(VoltaFormat.number(min($0, c.years), digits: 1)) of \(Int(c.years)) years" } ?? "Set purchase date",
                     fraction: yearFraction)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .voltaCardBackground()
    }

    private func progress(label: String, detail: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 10, weight: .semibold)).tracking(1.2).textCase(.uppercase).foregroundStyle(AnalyticsStyle.tertiary)
                Spacer()
                Text(detail).font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .foregroundStyle(fraction == nil ? AnalyticsStyle.tertiary : .white.opacity(0.85))
            }
            AnalyticsBar(fraction: fraction,
                         colors: (fraction ?? 0) >= 0.9 ? [AnalyticsStyle.amber.opacity(0.6), AnalyticsStyle.amber] : [AnalyticsStyle.mint, AnalyticsStyle.blue])
        }
        .accessibilityElement(children: .combine)
    }

    private var purchaseSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                DatePicker("Purchase date",
                           selection: Binding(get: { purchaseDate ?? .now }, set: { setPurchaseDate($0) }),
                           in: ...Date.now, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(ScreenKit.blue)
                if purchaseDate != nil {
                    Button("Clear date", role: .destructive) { setPurchaseDate(nil); editingDate = false }
                        .font(.system(size: 15, weight: .medium))
                }
                Spacer()
            }
            .padding(VoltaSpacing.screen)
            .voltaScreenBackground()
            .navigationTitle("Purchase date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if purchaseDate == nil { setPurchaseDate(.now) }
                        editingDate = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func load() async {
        let source = dataSource, id = vehicleID
        do {
            async let vehicles = source.vehicles()
            let status = try? await source.status(vehicleID: id)
            let vehicle = try await vehicles.first { $0.id == id }
            state = .loaded(Snapshot(vehicle: vehicle, odometerKm: status?.odometerKm))
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

#Preview("Populated") {
    NavigationStack { SpecsWarrantyView() }.voltaPreviewEnvironment()
}

#Preview("Empty") {
    NavigationStack { SpecsWarrantyView() }.voltaPreviewEnvironment(empty: true)
}
