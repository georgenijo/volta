import SwiftUI

struct MaintenanceView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var state: Loadable<ServiceState> = .loading
    @State private var generation = UUID()
    @State private var adding = false
    @State private var completing: ServiceItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LoadableContent(state: state, retry: load) { data in
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Recorded odometer")
                            if let km = data.odometerKm {
                                ScreenKit.Numeral(value: VoltaFormat.number(units.distanceValue(km: km), digits: 0), unit: units.distanceUnit, size: 48)
                                if let date = data.recordedAt {
                                    Text("\(data.source == "fleet_telemetry" ? "Telemetry" : "TeslaMate") · \(date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(ScreenKit.secondary)
                                }
                            } else {
                                Text("No odometer recorded yet. You can still log service dates.").foregroundStyle(ScreenKit.secondary)
                            }
                        }
                    }
                    Text("Personal reminders, not a service recommendation. Set intervals for your vehicle. Defaults: rotation 6,250 mi, filter 2 years, brake fluid check 4 years, wipers 1 year. Reminders appear here when you open Maintenance.")
                        .font(.caption).foregroundStyle(ScreenKit.secondary)
                    Button { adding = true } label: { Label("Add service item", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(ScreenKit.mint)
                    if data.items.isEmpty {
                        EmptyState(systemImage: "wrench.and.screwdriver", title: "Start your service log", message: "Add a suggested or custom item, then record the last service date and odometer to establish its next due point.")
                    }
                    ForEach(data.items) { item in
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(item.name).font(.headline)
                                    Spacer()
                                    if let progress = item.progress {
                                        ZStack {
                                            Circle().stroke(ScreenKit.hairline, lineWidth: 4)
                                            Circle().trim(from: 0, to: progress).stroke(progress >= 1 ? ScreenKit.amber : ScreenKit.mint, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                                            Text("\(Int(progress * 100))%").font(.system(size: 10, weight: .semibold))
                                        }.frame(width: 44, height: 44)
                                    }
                                }
                                Text(interval(item)).font(.caption).foregroundStyle(ScreenKit.secondary)
                                if let km = item.remainingKm {
                                    Text(km > 0 ? "Due in \(units.formatDistance(km, fractionDigits: 0))" : "Distance interval reached · \(units.formatDistance(-km, fractionDigits: 0)) past due")
                                } else if item.intervalKm != nil {
                                    Text("Distance due unknown — record a service odometer and wait for a current reading.").font(.caption).foregroundStyle(ScreenKit.secondary)
                                }
                                if let days = item.remainingDays {
                                    Text(days > 0 ? "Due in \(days) days" : days == 0 ? "Due today" : "\(-days) days past due")
                                    if let date = item.nextDate { Text("Next: \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(ScreenKit.secondary) }
                                } else if item.intervalMonths != nil {
                                    Text("Date due unknown — record the last completion.").font(.caption).foregroundStyle(ScreenKit.secondary)
                                }
                                if let progress = item.progress { ProgressView(value: progress).tint(progress >= 1 ? ScreenKit.amber : ScreenKit.mint) }
                                Button("Record completion") { completing = item }.buttonStyle(.bordered)
                            }
                        }
                    }
                    SectionLabel("Service history")
                    if data.events.isEmpty { Text("No completions logged yet.").foregroundStyle(ScreenKit.secondary) }
                    ForEach(data.events) { event in
                        Card {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(data.items.first { $0.id == event.itemId }?.name ?? "Service").font(.headline)
                                Text(event.completedAt.formatted(date: .abbreviated, time: .omitted))
                                Text(event.odometerKm.map { units.formatDistance($0, fractionDigits: 0) } ?? "Odometer not recorded").foregroundStyle(ScreenKit.secondary)
                            }
                        }
                    }
                }
            }.padding(.horizontal, ScreenKit.horizontalPadding).padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage("Maintenance")
        .task(id: vehicleID) { await load() }
        .refreshable { await load() }
        .onChange(of: vehicleID) { _, _ in adding = false; completing = nil }
        .sheet(isPresented: $adding) {
            let id = vehicleID
            ServiceItemForm { input in
                try await dataSource.addService(vehicleID: id, item: input)
                await load()
            }
        }
        .sheet(item: $completing) { item in
            let id = vehicleID
            ServiceCompletionForm(item: item, odometerKm: currentOdometer) { event in
                try await dataSource.completeService(vehicleID: id, itemID: item.id, event: event)
                await load()
            }
        }
    }
    private var currentOdometer: Double? { if case .loaded(let data) = state { data.odometerKm } else { nil } }
    private func interval(_ item: ServiceItem) -> String {
        [item.intervalKm.map { "Every \(units.formatDistance($0, fractionDigits: 0))" }, item.intervalMonths.map { "Every \($0) months" }].compactMap { $0 }.joined(separator: " · ")
    }
    @MainActor private func load() async {
        let id = vehicleID, token = UUID(); generation = token; state = .loading
        do {
            let result = try await dataSource.service(vehicleID: id)
            guard !Task.isCancelled, generation == token, vehicleID == id else { return }
            state = .loaded(result)
        } catch {
            guard !Task.isCancelled, generation == token, vehicleID == id else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

private struct ServiceItemForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units
    let save: (ServiceItemInput) async throws -> Void
    @State private var preset = 0
    @State private var name = ServiceItemInput.presets[0].name
    @State private var distance = ""
    @State private var months = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Picker("Suggested item", selection: $preset) {
                    ForEach(0..<ServiceItemInput.presets.count, id: \.self) { index in Text(ServiceItemInput.presets[index].name).tag(index) }
                    Text("Custom").tag(ServiceItemInput.presets.count)
                }.onChange(of: preset) { _, _ in applyPreset() }
                TextField("Service name", text: $name)
                TextField("Distance interval (\(units.distanceUnit), optional)", text: $distance).keyboardType(.decimalPad)
                TextField("Month interval (optional)", text: $months).keyboardType(.numberPad)
                Text("Set at least one interval. When both are set, the first reached is due. Log a completion to start the interval.").font(.caption)
                if let error { Text(error).foregroundStyle(ScreenKit.red) }
                Button(busy ? "Saving…" : "Add item") { Task { await submit() } }.disabled(busy)
            }.navigationTitle("Add service item")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
                .disabled(busy).interactiveDismissDisabled(busy)
                .onAppear { applyPreset() }
        }.preferredColorScheme(.dark)
    }
    private func applyPreset() {
        guard preset < ServiceItemInput.presets.count else { name = ""; distance = ""; months = ""; return }
        let value = ServiceItemInput.presets[preset]; name = value.name
        distance = value.intervalKm.map { String(units.distanceValue(km: $0)) } ?? ""
        months = value.intervalMonths.map(String.init) ?? ""
    }
    private func submit() async {
        guard let input = ServiceFormValidation.item(name: name, distance: distance, months: months, units: units) else { error = "Enter a name and a positive distance or whole month interval."; return }
        busy = true; error = nil
        do { try await save(input); dismiss() } catch { self.error = error.localizedDescription }
        busy = false
    }
}
private struct ServiceCompletionForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units
    let item: ServiceItem
    let odometerKm: Double?
    let save: (ServiceEventInput) async throws -> Void
    @State private var date = Date.now
    @State private var odometer = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Text(item.name).font(.headline)
                DatePicker("Completed", selection: $date, in: ...Date.now, displayedComponents: .date)
                TextField("Odometer (\(units.distanceUnit), optional)", text: $odometer).keyboardType(.decimalPad)
                Text("Enter the odometer at the service date. The current recorded reading is suggested; adjust it for older service. A blank value leaves distance reminders unknown.").font(.caption)
                if let error { Text(error).foregroundStyle(ScreenKit.red) }
                Button(busy ? "Saving…" : "Save completion") { Task { await submit() } }.disabled(busy)
            }.navigationTitle("Record completion")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
                .disabled(busy).interactiveDismissDisabled(busy)
                .onAppear { odometer = odometerKm.map { String(units.distanceValue(km: $0)) } ?? "" }
        }.preferredColorScheme(.dark)
    }
    private func submit() async {
        let km: Double?
        if odometer.trimmingCharacters(in: .whitespaces).isEmpty { km = nil }
        else if let parsed = ServiceFormValidation.distance(odometer, units: units), parsed >= 0, parsed <= 10000000 { km = parsed }
        else { error = "Enter a valid odometer or leave it blank."; return }
        busy = true; error = nil
        do { try await save(.init(completedAt: date, odometerKm: km)); dismiss() } catch { self.error = error.localizedDescription }
        busy = false
    }
}
enum ServiceFormValidation {
    static func distance(_ text: String, units: UnitPreferences) -> Double? {
        guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else { return nil }
        return units.distance == .miles ? number * 1.609344 : number
    }
    static func item(name: String, distance: String, months: String, units: UnitPreferences) -> ServiceItemInput? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 100 else { return nil }
        let km = distance.isEmpty ? nil : self.distance(distance, units: units)
        let count = months.isEmpty ? nil : Int(months)
        guard distance.isEmpty || (km != nil && km! > 0 && km! <= 1000000),
              months.isEmpty || (count != nil && count! > 0 && count! <= 1200), km != nil || count != nil else { return nil }
        return .init(name: title, intervalKm: km, intervalMonths: count)
    }
}
#Preview { NavigationStack { MaintenanceView() }.voltaPreviewEnvironment() }
