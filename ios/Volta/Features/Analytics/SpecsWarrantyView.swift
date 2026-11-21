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
        Coverage(name: "Basic vehicle", symbol: "car", years: 4, miles: 50_000),
        Coverage(name: "Battery & drive unit", symbol: "battery.100percent.bolt", years: 8, miles: 120_000),
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
        // Wide: the car and its specs beside warranty coverage.
        ScreenKit.Page(scroll: "specs", splits: state.value != nil, spacing: 22) {
            LoadableContent(state: state, retry: load, errorTitle: "Couldn't load vehicle") { snapshot in
                if let vehicle = snapshot.vehicle {
                    hero(vehicle, odometer: snapshot.odometerKm).voltaFocusIn(0)
                    specs(vehicle).voltaFocusIn(1)
                } else {
                    EmptyState(systemImage: "car", title: "No vehicle", message: "TeslaMate hasn't reported a vehicle yet. It appears here once the car is logged.")
                        .padding(.vertical, 40)
                }
            }
        } secondary: {
            if let snapshot = state.value { warranty(odometerKm: snapshot.odometerKm) }
        }
        .screenKitPage("Specs & warranty", screen: "specs")
        .task(id: vehicleID) { await load() }
        .task(id: storageKey) {
            let raw = storageKey.map { UserDefaults.standard.double(forKey: $0) } ?? 0
            purchaseDate = raw > 0 ? Date(timeIntervalSince1970: raw) : nil
        }
        .sheet(isPresented: $editingDate) { purchaseSheet }
    }

    private func hero(_ v: Vehicle, odometer: Double?) -> some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(v.name, trailing: v.model)
                ScreenKit.RollingNumeral(value: odometer.map { units.distanceValue(km: $0) }, unit: units.distanceUnit, size: 52)
                Text("Odometer").font(.subheadline).foregroundStyle(ScreenKit.secondary)
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
                    Text(row.1 ?? "—").font(.subheadline).foregroundStyle(ScreenKit.secondary)
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
                    Text(purchaseDate?.formatted(date: .abbreviated, time: .omitted) ?? "Set date")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(purchaseDate == nil ? Color.voltaBlueText : ScreenKit.secondary)
                    ScreenKit.Chevron()
                }
                .voltaCardBackground()
            }
            .buttonStyle(VoltaPressStyle())

            ForEach(Array(Self.coverages.enumerated()), id: \.element.id) { index, coverage in
                coverageCard(coverage, odometerKm: odometerKm).voltaFocusIn(index + 1)
            }
            Text("Tesla's standard US limited warranty terms. Coverage ends at whichever limit comes first.")
                .font(.caption).foregroundStyle(ScreenKit.secondary).padding(.horizontal, 4)
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
                    Image(systemName: c.symbol).foregroundStyle(ScreenKit.secondary).accessibilityHidden(true)
                    Text(c.name).font(.headline).foregroundStyle(.voltaTextPrimary)
                    Spacer()
                    // Covered is the normal state, so it stays quiet; expired is the problem.
                    Text(status == .expired ? "Expired" : status == .active ? "Covered" : "Unknown")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(status == .expired ? ScreenKit.red : ScreenKit.secondary)
                }
                progress(label: "Distance",
                         detail: "\(units.formatDistance(odometerKm, fractionDigits: 0)) of \(units.formatDistance(limitDistanceKm, fractionDigits: 0))",
                         fraction: mileFraction, high: units.formatDistance(limitDistanceKm, fractionDigits: 0))
                progress(label: "Time",
                         detail: yearsUsed.map { "\(VoltaFormat.number(min($0, c.years), digits: 1)) of \(Int(c.years)) years" } ?? "Set purchase date",
                         fraction: yearFraction, high: "\(Int(c.years)) years")
            }
        }
    }

    /// Coverage used, filled from zero to the limit: grey while there is room,
    /// amber in the last tenth, red once a limit has passed.
    private func progress(label: String, detail: String, fraction: Double?, high: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(label).voltaLabelStyle()
                Spacer()
                Text(detail).font(.footnote).foregroundStyle(fraction == nil ? ScreenKit.tertiary : Color.voltaTextPrimary).monospacedDigit()
            }
            LevelBar(value: fraction.map { min($0, 1) },
                     color: (fraction ?? 0) >= 1 ? ScreenKit.red : (fraction ?? 0) >= 0.9 ? ScreenKit.amber : ScreenKit.secondary,
                     lowLabel: "Start", highLabel: high)
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
                        .font(.callout.weight(.medium))
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
