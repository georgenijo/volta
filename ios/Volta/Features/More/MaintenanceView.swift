import SwiftUI

struct MaintenanceView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var state: Loadable<ServiceState> = .loading
    @State private var generation = UUID()
    @State private var adding = false
    @State private var completing: ServiceItem?
    @State private var editingItem: ServiceItem?
    @State private var editingEvent: ServiceEvent?
    @State private var deletingItem: ServiceItem?
    @State private var deletingEvent: ServiceEvent?
    @State private var mutationError: String?
    @State private var mutating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LoadableContent(state: state, retry: load) { data in
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Recorded odometer")
                                .font(.system(size: 11, weight: .semibold)).tracking(1.5).textCase(.uppercase)
                                .foregroundStyle(ScreenKit.tertiary)
                            if let km = data.odometerKm {
                                BigNumber(VoltaFormat.number(units.distanceValue(km: km), digits: 0), unit: units.distanceUnit, size: 56, weight: .bold)
                                if let date = data.recordedAt {
                                    Text("\(data.source == "fleet_telemetry" ? "Telemetry" : "TeslaMate") · \(VoltaFormat.dateTime(date))")
                                        .font(.system(size: 12, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                                }
                            } else {
                                Text("No odometer recorded yet. You can still log service dates.")
                                    .font(.system(size: 13, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    Text("Personal reminders, not a service recommendation. Set intervals for your vehicle. Suggested intervals to add: rotation 6,250 mi, filter 2 years, brake fluid check 4 years, wipers 1 year. Add an item and record its last completion to start reminders. Due status appears here when you open Maintenance.")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(ScreenKit.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    PillButton("Add service item", systemImage: "plus", size: .wide, style: .accent) { adding = true }
                    if data.items.isEmpty {
                        EmptyState(systemImage: "wrench.and.screwdriver", title: "Start your service log", message: "Add a suggested or custom item, then record the last service date and odometer to establish its next due point.")
                    }
                    if let mutationError { Text(mutationError).foregroundStyle(ScreenKit.red) }
                    ForEach(data.items) { item in
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(item.name).font(.system(size: 16, weight: .semibold))
                                    Spacer()
                                    Menu {
                                        Button("Edit item") { editingItem = item }
                                        Button("Delete item and history", role: .destructive) { deletingItem = item }
                                    } label: {
                                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(ScreenKit.secondary).frame(width: 32, height: 32)
                                    }.disabled(mutating)
                                    if let progress = item.progress {
                                        let tint = progress >= 1 ? ScreenKit.amber : ScreenKit.mint
                                        ZStack {
                                            Circle().stroke(Color.white.opacity(0.06), lineWidth: 3)
                                            SweepIn { p in
                                                let reach = min(min(1, progress) * p, 1)
                                                ZStack {
                                                    Circle().trim(from: 0, to: reach).stroke(tint.opacity(0.5 + 0.4 * VoltaMotion.bloom(p)), style: StrokeStyle(lineWidth: 5, lineCap: .round)).blur(radius: 4)
                                                    Circle().trim(from: 0, to: reach).stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                                }
                                                .rotationEffect(.degrees(-90))
                                            }
                                            Text("\(Int(progress * 100))%").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                        }.frame(width: 44, height: 44)
                                    }
                                }
                                Text(interval(item)).font(.system(size: 12, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                                if let km = item.remainingKm {
                                    Text(km > 0 ? "Due in \(units.formatDistance(km, fractionDigits: 0))" : "Distance interval reached · \(units.formatDistance(-km, fractionDigits: 0)) past due")
                                } else if item.intervalKm != nil {
                                    Text("Distance due unknown — record a service odometer and wait for a current reading.").font(.system(size: 12, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                                }
                                if let days = item.remainingDays {
                                    Text(days > 0 ? "Due in \(days) days" : days == 0 ? "Due today" : "\(-days) days past due")
                                    if let date = item.nextDate { Text("Next: \(date.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 12, weight: .medium)).foregroundStyle(ScreenKit.secondary) }
                                } else if item.intervalMonths != nil {
                                    Text("Date due unknown — record the last completion.").font(.system(size: 12, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                                }
                                if let progress = item.progress { ScreenKit.ProgressBar(fraction: progress, tint: progress >= 1 ? ScreenKit.amber : ScreenKit.mint, height: 4) }
                                PillButton("Record completion", systemImage: "checkmark") { completing = item }
                            }
                        }
                    }
                    Text("Service history")
                        .font(.system(size: 11, weight: .semibold)).tracking(1.5).textCase(.uppercase)
                        .foregroundStyle(ScreenKit.tertiary)
                        .padding(.top, 14)
                    if data.events.isEmpty { Text("No completions logged yet.").font(.system(size: 13, weight: .medium)).foregroundStyle(ScreenKit.secondary) }
                    ForEach(data.events) { event in
                        Card {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(data.items.first { $0.id == event.itemId }?.name ?? "Service").font(.system(size: 16, weight: .semibold))
                                    Spacer()
                                    Menu {
                                        Button("Correct completion") { editingEvent = event }
                                        Button("Delete completion", role: .destructive) { deletingEvent = event }
                                    } label: {
                                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(ScreenKit.secondary).frame(width: 32, height: 32)
                                    }.disabled(mutating)
                                }
                                Text(event.completedAt.formatted(date: .abbreviated, time: .omitted))
                                Text(event.odometerKm.map { units.formatDistance($0, fractionDigits: 0) } ?? "Odometer not recorded").foregroundStyle(ScreenKit.secondary)
                            }
                        }
                    }
                }
            }.padding(.horizontal, ScreenKit.horizontalPadding).padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage("Maintenance")
        .voltaArrivalScope(isReady: state.isSettled)
        .task(id: vehicleID) { await load() }
        .refreshable { await load() }
        .onChange(of: vehicleID) { _, _ in adding = false; completing = nil; editingItem = nil; editingEvent = nil; deletingItem = nil; deletingEvent = nil }
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
        .sheet(item: $editingItem) { item in
            let id = vehicleID
            ServiceItemForm(existing: item) { input in
                try await dataSource.updateService(vehicleID: id, itemID: item.id, item: input); await load()
            }
        }
        .sheet(item: $editingEvent) { event in
            let id = vehicleID
            if let item = state.value?.items.first(where: { $0.id == event.itemId }) {
                ServiceCompletionForm(item: item, odometerKm: event.odometerKm, existing: event) { input in
                    try await dataSource.updateServiceEvent(vehicleID: id, eventID: event.id, event: input); await load()
                }
            }
        }
        .confirmationDialog("Delete item and all its service history?", isPresented: Binding(get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } }), presenting: deletingItem) { item in
            Button("Delete item and history", role: .destructive) {
                let id = vehicleID
                Task { await mutate { try await dataSource.deleteService(vehicleID: id, itemID: item.id) } }
            }
        }
        .confirmationDialog("Delete this completion?", isPresented: Binding(get: { deletingEvent != nil }, set: { if !$0 { deletingEvent = nil } }), presenting: deletingEvent) { event in
            Button("Delete completion", role: .destructive) {
                let id = vehicleID
                Task { await mutate { try await dataSource.deleteServiceEvent(vehicleID: id, eventID: event.id) } }
            }
        }

    }
    private var currentOdometer: Double? { if case .loaded(let data) = state { data.odometerKm } else { nil } }
    private func interval(_ item: ServiceItem) -> String {
        [item.intervalKm.map { "Every \(units.formatDistance($0, fractionDigits: 0))" }, item.intervalMonths.map { "Every \($0) months" }].compactMap { $0 }.joined(separator: " · ")
    }
    @MainActor private func mutate(_ operation: () async throws -> Void) async {
        guard !mutating else { return }; mutating = true; mutationError = nil
        defer { mutating = false }
        do { try await operation(); await load() } catch { mutationError = error.localizedDescription }
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
    var existing: ServiceItem? = nil
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
                if existing == nil { Picker("Suggested item", selection: $preset) {
                    ForEach(0..<ServiceItemInput.presets.count, id: \.self) { index in Text(ServiceItemInput.presets[index].name).tag(index) }
                    Text("Custom").tag(ServiceItemInput.presets.count)
                }.onChange(of: preset) { _, _ in applyPreset() } }
                TextField("Service name", text: $name)
                TextField("Distance interval (\(units.distanceUnit), optional)", text: $distance).keyboardType(.decimalPad)
                TextField("Month interval (optional)", text: $months).keyboardType(.numberPad)
                Text("Set at least one interval. When both are set, the first reached is due. Log a completion to start the interval.").font(.caption)
                if let error { Text(error).foregroundStyle(ScreenKit.red) }
                Button(busy ? "Saving…" : existing == nil ? "Add item" : "Save item") { Task { await submit() } }.disabled(busy)
            }.navigationTitle(existing == nil ? "Add service item" : "Edit service item")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
                .disabled(busy).interactiveDismissDisabled(busy)
                .onAppear {
                    if let existing {
                        preset = ServiceItemInput.presets.count; name = existing.name
                        distance = existing.intervalKm.map { ServiceFormValidation.number(units.distanceValue(km: $0)) } ?? ""
                        months = existing.intervalMonths.map(String.init) ?? ""
                    } else { applyPreset() }
                }
        }.preferredColorScheme(.dark)
    }
    private func applyPreset() {
        guard preset < ServiceItemInput.presets.count else { name = ""; distance = ""; months = ""; return }
        let value = ServiceItemInput.presets[preset]; name = value.name
        distance = value.intervalKm.map { ServiceFormValidation.number(units.distanceValue(km: $0)) } ?? ""
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
    var existing: ServiceEvent? = nil
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
                .onAppear { if let existing { date = existing.completedAt }; odometer = odometerKm.map { ServiceFormValidation.number(units.distanceValue(km: $0)) } ?? "" }
        }.preferredColorScheme(.dark)
    }
    private func submit() async {
        let km: Double?
        if odometer.trimmingCharacters(in: .whitespaces).isEmpty { km = nil }
        else if let parsed = ServiceFormValidation.distance(odometer, units: units), parsed >= 0, parsed <= 10000000 { km = parsed }
        else { error = "Enter a valid odometer or leave it blank."; return }
        busy = true; error = nil
        do { try await save(.init(completedAt: Calendar.current.startOfDay(for: date), odometerKm: km)); dismiss() } catch { self.error = error.localizedDescription }
        busy = false
    }
}
enum ServiceFormValidation {
    // Locale-independent editable numbers; truncating avoids making a suggested
    // completed odometer fractionally greater than the actual recorded reading.
    static func number(_ value: Double) -> String {
        (floor(value * 100) / 100).formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...2)))
    }
    static func distance(_ text: String, units: UnitPreferences) -> Double? {
        guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else { return nil }
        return units.distance == .miles ? number * 1.609344 : number
    }
    static func item(name: String, distance: String, months: String, units: UnitPreferences) -> ServiceItemInput? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.unicodeScalars.count <= 100, !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }) else { return nil }
        let km = distance.isEmpty ? nil : self.distance(distance, units: units)
        let count = months.isEmpty ? nil : Int(months)
        guard distance.isEmpty || (km != nil && km! > 0 && km! <= 1000000),
              months.isEmpty || (count != nil && count! > 0 && count! <= 1200), km != nil || count != nil else { return nil }
        return .init(name: title, intervalKm: km, intervalMonths: count)
    }
}
#Preview { NavigationStack { MaintenanceView() }.voltaPreviewEnvironment() }
