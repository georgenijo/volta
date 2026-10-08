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
                VStack(alignment: .leading, spacing: 22) {
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
        .screenKitPage("Specs & Warranty")
        .task(id: vehicleID) { await load() }
        .task(id: storageKey) {
            let raw = storageKey.map { UserDefaults.standard.double(forKey: $0) } ?? 0
            purchaseDate = raw > 0 ? Date(timeIntervalSince1970: raw) : nil
        }
        .sheet(isPresented: $editingDate) { purchaseSheet }
    }

    private func hero(_ v: Vehicle, odometer: Double?) -> some View {
        Card(padding: 20, tint: ScreenKit.mint) {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(v.name, trailing: v.model)
                ScreenKit.Numeral(value: odometer.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—", unit: units.distanceUnit, size: 52)
                Text("Odometer").font(.system(size: 14)).foregroundStyle(ScreenKit.secondary)
            }
        }
    }

    private func specs(_ v: Vehicle) -> some View {
        let rows: [(String, String?)] = [
            ("Model", v.model), ("Trim", v.trim), ("Color", v.exteriorColor),
            ("VIN", v.vinSuffix.map { "••••\($0)" }), ("Software", v.firmware),
        ]
        return ScreenKit.GroupCard(title: "Specs") {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                ScreenKit.ValueRow(title: row.0, showsDivider: index < rows.count - 1) {
                    Text(row.1 ?? "—").font(.system(size: 15)).foregroundStyle(ScreenKit.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func warranty(odometerKm: Double?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Warranty").padding(.horizontal, 4)
            Button { editingDate = true } label: {
                ScreenKit.ValueRow(title: "Purchase date", subtitle: model.isLaunchDemo ? "Not saved in launch demo" : "Stored on this device only", showsDivider: false) {
                    Text(purchaseDate?.formatted(date: .abbreviated, time: .omitted) ?? "Set")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(purchaseDate == nil ? ScreenKit.blue : ScreenKit.secondary)
                    ScreenKit.Chevron()
                }
                .voltaCardBackground()
            }
            .buttonStyle(VoltaPressStyle())

            ForEach(Self.coverages) { coverage in
                coverageCard(coverage, odometerKm: odometerKm)
            }
            Text("Tesla's standard US limited warranty terms. Coverage ends at whichever limit comes first.")
                .font(.system(size: 12)).foregroundStyle(ScreenKit.secondary).padding(.horizontal, 4)
        }
    }

    private func coverageCard(_ c: Coverage, odometerKm: Double?) -> some View {
        let milesUsed = odometerKm.map { $0 / 1.609344 }
        let mileFraction = milesUsed.map { $0 / c.miles }
        let yearsUsed = purchaseDate.map { Date.now.timeIntervalSince($0) / (365.25 * 86_400) }
        let yearFraction = yearsUsed.map { $0 / c.years }
        let limitDistanceKm = c.miles * 1.609344
        let status = AnalyticsMath.coverageStatus(purchaseDate: purchaseDate, odometerKm: odometerKm, years: c.years, limitKm: limitDistanceKm)

        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: c.symbol).foregroundStyle(ScreenKit.mint)
                    Text(c.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    Text(status == .expired ? "EXPIRED" : status == .active ? "ACTIVE" : "UNKNOWN")
                        .font(.system(size: 11, weight: .bold)).tracking(1.2)
                        .foregroundStyle(status == .expired ? ScreenKit.red : status == .active ? ScreenKit.green : ScreenKit.secondary)
                }
                progress(label: "Distance",
                         detail: "\(units.formatDistance(odometerKm, fractionDigits: 0)) of \(units.formatDistance(limitDistanceKm, fractionDigits: 0))",
                         fraction: mileFraction)
                progress(label: "Time",
                         detail: yearsUsed.map { "\(VoltaFormat.number(min($0, c.years), digits: 1)) of \(Int(c.years)) years" } ?? "Set purchase date",
                         fraction: yearFraction)
            }
        }
    }

    private func progress(label: String, detail: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(label.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.5).foregroundStyle(ScreenKit.secondary)
                Spacer()
                Text(detail).font(.system(size: 13)).foregroundStyle(fraction == nil ? ScreenKit.tertiary : .white).monospacedDigit()
            }
            ScreenKit.ProgressBar(fraction: fraction ?? 0,
                                  tint: (fraction ?? 0) >= 0.9 ? ScreenKit.amber : ScreenKit.blue)
        }
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
