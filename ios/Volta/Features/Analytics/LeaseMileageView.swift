import Charts
import SwiftUI

/// Lease mileage against the owner's own lease figures: distance used and left,
/// the pace needed to finish on allowance against the actual pace, a projection
/// at the end of the term, and recorded distance against the allowance line.
/// The terms are entered by hand and stored only on this phone.
struct LeaseMileageView: View {
    struct Snapshot: Sendable {
        var odometerKm: Double?
        var buckets: [MileageBucket]
    }

    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<Snapshot> = .loading
    @State private var terms: LeaseTerms?
    /// True once stored terms were read for the current key.
    @State private var termsLoaded = false
    @State private var editing = false

    /// UserDefaults key scoped like the warranty purchase date: per paired
    /// server (or demo) and vehicle. nil = don't persist (launch demo).
    nonisolated static func storageKey(serverURL: String, isDemo: Bool, isLaunchDemo: Bool, vehicleID: Int) -> String? {
        if isLaunchDemo { return nil }
        let scope = isDemo ? "demo" : AnalyticsMath.serverScope(serverURL)
        return "volta.lease.terms.\(scope).\(vehicleID)"
    }

    private var storageKey: String? {
        Self.storageKey(serverURL: model.settings.serverURL, isDemo: model.isDemoMode, isLaunchDemo: model.isLaunchDemo, vehicleID: vehicleID)
    }

    private func save(_ new: LeaseTerms?) {
        terms = new
        guard let storageKey else { return }
        if let new, let data = try? JSONEncoder().encode(new) { UserDefaults.standard.set(data, forKey: storageKey) }
        else { UserDefaults.standard.removeObject(forKey: storageKey) }
    }

    private var progress: LeaseProgress? {
        guard let terms, let snapshot = state.value else { return nil }
        return LeaseProgress(terms: terms, odometerKm: snapshot.odometerKm, now: .now)
    }

    var body: some View {
        ScreenKit.Page(scroll: "lease", splits: progress != nil) {
            LoadableContent(state: state, retry: load) { snapshot in
                if let terms, let progress {
                    hero(progress)
                    pace(progress)
                    projection(progress)
                    if progress.odometerBelowStart {
                        InlineBanner(systemImage: "exclamationmark.triangle",
                                     message: "The car's odometer (\(units.formatDistance(snapshot.odometerKm, fractionDigits: 0))) reads below your starting odometer (\(units.formatDistance(terms.startOdometerKm, fractionDigits: 0))). Check your lease figures.",
                                     tint: ScreenKit.amber)
                    }
                } else if termsLoaded {
                    emptyState
                }
            }
        } secondary: {
            if let terms, let progress, let snapshot = state.value {
                chart(progress, terms: terms, snapshot: snapshot)
                termsCard(terms)
            }
        }
        .screenKitPage("Lease Mileage", screen: "lease")
        .task(id: vehicleID) { await load() }
        .task(id: storageKey) {
            let data = storageKey.flatMap { UserDefaults.standard.data(forKey: $0) }
            terms = data.flatMap { try? JSONDecoder().decode(LeaseTerms.self, from: $0) }.flatMap { $0.isValid ? $0 : nil }
            termsLoaded = true
        }
        .sheet(isPresented: $editing) {
            LeaseTermsSheet(terms: terms, odometerKm: state.value?.odometerKm, units: units,
                            isLaunchDemo: model.isLaunchDemo, onSave: save)
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 20) {
            EmptyState(systemImage: "doc.text.magnifyingglass", title: "Track your lease",
                       message: "Enter your lease start, term, mileage allowance and starting odometer to see how your driving compares. Your figures stay on this iPhone.")
            PillButton("Set up lease", systemImage: "plus", size: .wide, style: .accent) { editing = true }
                .accessibilityIdentifier("button.lease.setup")
        }
        .padding(.top, 40)
    }

    // MARK: Hero

    private func hero(_ p: LeaseProgress) -> some View {
        Card(padding: 20, tint: ScreenKit.mint) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(p.phase == .ended ? "Used over the lease" : "Used so far", trailing: phaseLabel(p))
                ScreenKit.Numeral(value: p.usedKm.map { number($0) } ?? "—", unit: units.distanceUnit, size: 52)
                Text("of \(units.formatDistance(p.allowanceKm, fractionDigits: 0)) allowance")
                    .font(.subheadline).foregroundStyle(ScreenKit.secondary)
                LeaseProgressBar(used: p.usedFraction, time: p.timeFraction)
                    .accessibilityElement()
                    .accessibilityLabel("Allowance used")
                    .accessibilityValue(p.usedFraction.map { "\(percent($0)) of allowance, \(percent(p.timeFraction)) of the term" }
                                        ?? "Unknown, \(percent(p.timeFraction)) of the term")
                HStack(alignment: .firstTextBaseline) {
                    legendDot(LeaseProgressBar.tint(used: p.usedFraction, time: p.timeFraction), "Distance used")
                    legendTick("Time elapsed")
                    Spacer(minLength: 0)
                }
                Text("Your lease figures, entered on this iPhone.")
                    .font(.caption).foregroundStyle(ScreenKit.tertiary)
            }
        }
    }

    private func phaseLabel(_ p: LeaseProgress) -> String {
        switch p.phase {
        case .notStarted: "Starts \(p.start.formatted(date: .abbreviated, time: .omitted))"
        case .ended: "Ended"
        case .active: "\(Int(p.remainingDays.rounded(.up))) days left"
        }
    }

    // MARK: Pace

    @ViewBuilder
    private func pace(_ p: LeaseProgress) -> some View {
        LazyVGrid(columns: ScreenKit.metricColumns, spacing: 12) {
            ScreenKit.Metric(label: "Remaining", value: p.remainingKm.map { number(max($0, 0)) } ?? "—", unit: units.distanceUnit,
                             caption: p.remainingKm.map { $0 < 0 ? "\(number(-$0)) \(units.distanceUnit) over" : "of allowance" },
                             symbol: "road.lanes")
            ScreenKit.Metric(label: "Even pace", value: p.usedKm == nil ? "—" : aheadValue(p), unit: p.usedKm == nil ? nil : units.distanceUnit,
                             caption: p.aheadOfPaceKm.map { $0 > 0 ? "Over an even pace" : "Under an even pace" }, symbol: "scalemass")
            ScreenKit.Metric(label: "Needed pace", value: p.neededKmPerDay.map { monthly($0) } ?? "—",
                             unit: p.neededKmPerDay == nil ? nil : "\(units.distanceUnit)/mo",
                             caption: p.phase == .active ? "To finish on allowance" : nil, symbol: "flag.checkered")
            ScreenKit.Metric(label: "Your pace", value: p.actualKmPerDay.map { monthly($0) } ?? "—",
                             unit: p.actualKmPerDay == nil ? nil : "\(units.distanceUnit)/mo",
                             caption: paceCaption(p), symbol: "speedometer")
        }
    }

    private func aheadValue(_ p: LeaseProgress) -> String {
        guard let ahead = p.aheadOfPaceKm else { return "—" }
        return (ahead > 0 ? "+" : ahead < 0 ? "−" : "") + number(abs(ahead))
    }

    private func paceCaption(_ p: LeaseProgress) -> String? {
        switch p.phase {
        case .notStarted: return nil
        case .ended: return "Over the term"
        case .active:
            guard let actual = p.actualKmPerDay else {
                return p.usedKm == nil ? "Odometer unknown" : "After the first week"
            }
            guard let needed = p.neededKmPerDay else { return nil }
            return actual > needed * 1.02 ? "Faster than needed" : "Within allowance"
        }
    }

    // MARK: Projection

    @ViewBuilder
    private func projection(_ p: LeaseProgress) -> some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(p.phase == .ended ? "At lease end" : "Projected at lease end",
                             trailing: p.end.formatted(date: .abbreviated, time: .omitted))
                if let projected = p.projectedKmAtEnd, let over = p.projectedOverKm {
                    ScreenKit.Numeral(value: number(projected), unit: units.distanceUnit, size: 40)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: over > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(over > 0 ? ScreenKit.red : ScreenKit.green)
                            .accessibilityHidden(true)
                        Text(over > 0 ? "\(units.formatDistance(over, fractionDigits: 0)) over allowance"
                                      : "\(units.formatDistance(-over, fractionDigits: 0)) under allowance")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    Text(p.isProjectionEstimate
                         ? "Estimate: your pace so far, continued to the end of the term. Your contract's excess-mileage rate applies to any overage."
                         : "Final distance against your allowance.")
                        .font(.footnote).foregroundStyle(ScreenKit.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(projectionUnavailable(p))
                        .font(.subheadline).foregroundStyle(ScreenKit.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func projectionUnavailable(_ p: LeaseProgress) -> String {
        if p.phase == .notStarted { return "The projection starts once the lease begins." }
        if p.usedKm == nil { return "Unavailable until the car's odometer is recorded." }
        return "Available after the first \(Int(LeaseProgress.minimumDaysForPace)) days of the lease."
    }

    // MARK: Chart

    @ViewBuilder
    private func chart(_ p: LeaseProgress, terms: LeaseTerms, snapshot: Snapshot) -> some View {
        let recorded = LeaseProgress.cumulative(snapshot.buckets, start: terms.start, now: .now)
        let recordedKm = recorded.last?.km ?? 0
        let today = min(Date.now, p.end)
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Distance against allowance", trailing: units.distanceUnit)
                if p.phase == .notStarted {
                    Text("The chart starts on \(p.start.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.subheadline).foregroundStyle(ScreenKit.secondary)
                } else {
                    Chart {
                        LineMark(x: .value("Date", p.start), y: .value("Distance", 0.0), series: .value("Series", "Allowance"))
                            .foregroundStyle(ScreenKit.secondary.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        LineMark(x: .value("Date", p.end), y: .value("Distance", units.distanceValue(km: p.allowanceKm)), series: .value("Series", "Allowance"))
                            .foregroundStyle(ScreenKit.secondary.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        ForEach(recorded, id: \.self) { point in
                            AreaMark(x: .value("Date", point.date), y: .value("Distance", units.distanceValue(km: point.km)))
                                .foregroundStyle(LinearGradient(colors: [ScreenKit.mint.opacity(0.3), ScreenKit.mint.opacity(0)],
                                                                startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.stepEnd)
                            LineMark(x: .value("Date", point.date), y: .value("Distance", units.distanceValue(km: point.km)),
                                     series: .value("Series", "Recorded"))
                                .foregroundStyle(ScreenKit.mint)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.stepEnd)
                        }
                        if p.phase == .active, let used = p.usedKm, let projected = p.projectedKmAtEnd {
                            // Estimate: today's odometer figure continued at the current pace.
                            LineMark(x: .value("Date", today), y: .value("Distance", units.distanceValue(km: used)),
                                     series: .value("Series", "Projection"))
                                .foregroundStyle(projectionTint(p))
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))
                            LineMark(x: .value("Date", p.end), y: .value("Distance", units.distanceValue(km: projected)),
                                     series: .value("Series", "Projection"))
                                .foregroundStyle(projectionTint(p))
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))
                        }
                        if p.phase == .active {
                            RuleMark(x: .value("Today", today))
                                .foregroundStyle(ScreenKit.hairline)
                                .lineStyle(StrokeStyle(lineWidth: 1))
                        }
                    }
                    .chartXScale(domain: p.start...max(p.end, p.start.addingTimeInterval(86_400)))
                    .chartYScale(domain: 0...max(units.distanceValue(km: max(p.allowanceKm, recordedKm, p.projectedKmAtEnd ?? 0)) * 1.05, 1))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).year())
                                .foregroundStyle(ScreenKit.secondary).font(.system(size: 10))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine().foregroundStyle(ScreenKit.hairline)
                            AxisValueLabel().foregroundStyle(ScreenKit.secondary).font(.system(size: 10))
                        }
                    }
                    .frame(height: 200)
                    .accessibilityElement()
                    .accessibilityLabel("Recorded distance against the allowance line")
                    .accessibilityValue("\(units.formatDistance(recordedKm, fractionDigits: 0)) recorded since the lease start. An even pace allows \(units.formatDistance(p.expectedKmToDate, fractionDigits: 0)) by today and \(units.formatDistance(p.allowanceKm, fractionDigits: 0)) by \(p.end.formatted(date: .abbreviated, time: .omitted)).")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) { chartLegend(p) }
                        VStack(alignment: .leading, spacing: 6) { chartLegend(p) }
                    }
                    if let note = coverageNote(recordedKm: recordedKm, usedKm: p.usedKm) {
                        Text(note).font(.footnote).foregroundStyle(ScreenKit.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The chart sums drives TeslaMate recorded; the totals above use the
    /// odometer. Say so when the two disagree, rather than scaling either.
    private func coverageNote(recordedKm: Double, usedKm: Double?) -> String? {
        guard let usedKm, usedKm > 0 else { return nil }
        guard abs(recordedKm - usedKm) > max(usedKm * 0.02, 1) else { return nil }
        return "The chart adds up recorded drives (\(units.formatDistance(recordedKm, fractionDigits: 0))). The odometer shows \(units.formatDistance(usedKm, fractionDigits: 0)) since your starting figure, which the totals use."
    }

    private func termsCard(_ terms: LeaseTerms) -> some View {
        let rows: [(String, String)] = [
            ("Start", terms.start.formatted(date: .abbreviated, time: .omitted)),
            ("End", terms.end().formatted(date: .abbreviated, time: .omitted)),
            ("Term", "\(terms.termMonths) months"),
            ("Allowance", units.formatDistance(terms.allowanceKm, fractionDigits: 0)),
            ("Starting odometer", units.formatDistance(terms.startOdometerKm, fractionDigits: 0)),
        ]
        return ScreenKit.GroupCard(title: "Your lease terms",
                                   footer: model.isLaunchDemo ? "Not saved in launch demo." : "Stored on this iPhone only. Volta never sends them to your server.") {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                ScreenKit.ValueRow(title: row.0, showsDivider: true) {
                    Text(row.1).font(.subheadline).foregroundStyle(ScreenKit.secondary)
                        .multilineTextAlignment(.trailing).monospacedDigit()
                }
            }
            Button { editing = true } label: {
                ScreenKit.ValueRow(title: "Edit lease terms", showsDivider: false) { ScreenKit.Chevron() }
            }
            .buttonStyle(VoltaPressStyle())
            .accessibilityIdentifier("row.lease.edit")
        }
    }

    // MARK: Helpers

    private func number(_ km: Double) -> String { VoltaFormat.number(units.distanceValue(km: km), digits: 0) }
    private func monthly(_ kmPerDay: Double) -> String { number(kmPerDay * LeaseProgress.daysPerMonth) }
    private func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded())) percent" }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(label).font(.caption).foregroundStyle(ScreenKit.secondary)
        }
    }

    @ViewBuilder private func chartLegend(_ p: LeaseProgress) -> some View {
        legendDot(ScreenKit.mint, "Recorded drives")
        legendDash("Allowance", color: ScreenKit.secondary)
        if p.phase == .active, p.projectedKmAtEnd != nil { legendDash("Projection (estimate)", color: projectionTint(p)) }
    }

    private func projectionTint(_ p: LeaseProgress) -> Color {
        (p.projectedOverKm ?? 0) > 0 ? ScreenKit.amber : ScreenKit.blue
    }

    private func legendTick(_ label: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(.white).frame(width: 2, height: 10).accessibilityHidden(true)
            Text(label).font(.caption).foregroundStyle(ScreenKit.secondary)
        }
    }

    private func legendDash(_ label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in Capsule().fill(color).frame(width: 4, height: 1.5) }
            }
            .accessibilityHidden(true)
            Text(label).font(.caption).foregroundStyle(ScreenKit.secondary)
        }
    }

    private func load() async {
        let source = dataSource, id = vehicleID
        do {
            async let buckets = source.mileage(vehicleID: id, bucket: .day)
            // The odometer is optional: without it the screen says "unknown".
            let status = try? await source.status(vehicleID: id)
            let snapshot = Snapshot(odometerKm: status?.odometerKm, buckets: try await buckets)
            withAnimation(.smooth) { state = .loaded(snapshot) }
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Distance used as a filled bar, with a tick where an even pace would be today.
private struct LeaseProgressBar: View {
    var used: Double?
    var time: Double

    /// Amber once distance runs ahead of time.
    static func tint(used: Double?, time: Double) -> Color {
        (used ?? 0) > time * 1.02 ? ScreenKit.amber : ScreenKit.mint
    }

    var body: some View {
        ScreenKit.ProgressBar(fraction: used ?? 0, tint: Self.tint(used: used, time: time), height: 8)
            .opacity(used == nil ? 0.4 : 1)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(.white)
                        .frame(width: 2, height: 16)
                        .offset(x: max(0, min(proxy.size.width - 2, proxy.size.width * time - 1)), y: -4)
                }
            }
            .padding(.vertical, 4)
    }
}

// MARK: - Terms sheet

/// Lease start, term, allowance and starting odometer, in display units.
struct LeaseTermsSheet: View {
    var terms: LeaseTerms?
    var odometerKm: Double?
    var units: UnitPreferences
    var isLaunchDemo: Bool
    var onSave: (LeaseTerms?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var start = Date.now
    @State private var months = 36
    @State private var allowanceText = ""
    @State private var odometerText = ""
    @FocusState private var focus: Field?

    private enum Field { case allowance, odometer }

    static let commonTerms = [24, 36, 39, 48]

    /// A whole, non-negative number in display units, or nil. Commas and spaces
    /// are ignored so "36,000" reads as 36000.
    static func parse(_ text: String) -> Double? {
        let cleaned = text.filter { !$0.isWhitespace && $0 != "," }
        guard let value = Double(cleaned), value.isFinite, value >= 0, value < 10_000_000 else { return nil }
        return value
    }

    private func km(_ display: Double) -> Double { units.distance == .miles ? display * 1.609344 : display }

    private var draft: LeaseTerms? {
        guard let allowance = Self.parse(allowanceText), allowance > 0, let odometer = Self.parse(odometerText) else { return nil }
        let terms = LeaseTerms(start: start, termMonths: months, allowanceKm: km(allowance), startOdometerKm: km(odometer))
        return terms.isValid ? terms : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Enter the figures from your lease contract. They stay on this iPhone\(isLaunchDemo ? " until you exit the demo" : "").")
                        .font(.subheadline).foregroundStyle(ScreenKit.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("screen.lease-terms")

                    VStack(alignment: .leading, spacing: 8) {
                        label("Lease start")
                        DatePicker("Lease start", selection: $start, displayedComponents: .date)
                            .labelsHidden()
                            .tint(ScreenKit.blue)
                            .accessibilityIdentifier("field.lease.start")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        label("Term")
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { termButtons }
                            VStack(alignment: .leading, spacing: 8) { termButtons }
                        }
                        Stepper(value: $months, in: LeaseTerms.termRange) {
                            Text("\(months) months").font(.body.weight(.semibold)).foregroundStyle(.white).monospacedDigit()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(ScreenKit.card, in: .rect(cornerRadius: 14))
                        .accessibilityIdentifier("field.lease.term")
                    }

                    numberField("Mileage allowance (\(units.distanceUnit), whole term)", text: $allowanceText, prompt: units.distance == .miles ? "36000" : "60000",
                                field: .allowance, valid: Self.parse(allowanceText).map { $0 > 0 } ?? allowanceText.isEmpty,
                                caption: "The total for the lease, not per year.", identifier: "field.lease.allowance")
                    numberField("Starting odometer (\(units.distanceUnit))", text: $odometerText, prompt: "12",
                                field: .odometer, valid: Self.parse(odometerText) != nil || odometerText.isEmpty,
                                caption: odometerKm.map { "The car reads \(units.formatDistance($0, fractionDigits: 0)) today." } ?? "As written on your contract.",
                                identifier: "field.lease.odometer")

                    if terms != nil {
                        Button("Remove lease", role: .destructive) { onSave(nil); dismiss() }
                            .font(.callout.weight(.medium))
                            .accessibilityIdentifier("button.lease.remove")
                    }
                }
                .padding(.horizontal, ScreenKit.horizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(ScreenKit.background.ignoresSafeArea())
            .navigationTitle("Lease terms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ScreenKit.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("button.lease.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if let draft { onSave(draft); dismiss() } }
                        .fontWeight(.semibold)
                        .disabled(draft == nil)
                        .accessibilityIdentifier("button.lease.save")
                }
                // The number pad has no return key: step to the next field, then close it.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(focus == .allowance ? "Next" : "Done") {
                        focus = focus == .allowance ? .odometer : nil
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("button.lease.keyboard")
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationBackground(ScreenKit.background)
        .onAppear {
            guard let terms else { return }
            start = terms.start
            months = terms.termMonths
            allowanceText = VoltaFormat.number(units.distanceValue(km: terms.allowanceKm), digits: 0).filter { $0.isNumber }
            odometerText = VoltaFormat.number(units.distanceValue(km: terms.startOdometerKm), digits: 0).filter { $0.isNumber }
        }
    }

    @ViewBuilder private var termButtons: some View {
        ForEach(Self.commonTerms, id: \.self) { value in
            Button { months = value } label: {
                Text("\(value) mo")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(months == value ? .white : ScreenKit.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(months == value ? Color.voltaRaised : ScreenKit.card, in: .capsule)
                    .overlay(Capsule().strokeBorder(months == value ? ScreenKit.blue : ScreenKit.hairline, lineWidth: 1))
            }
            .buttonStyle(VoltaPressStyle())
            .accessibilityLabel("\(value) months")
            .accessibilityAddTraits(months == value ? .isSelected : [])
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(ScreenKit.secondary)
    }

    private func numberField(_ title: String, text: Binding<String>, prompt: String, field: Field, valid: Bool,
                             caption: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            label(title)
            HStack(spacing: 6) {
                TextField(prompt, text: text)
                    .keyboardType(.numberPad)
                    .font(.title3.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .focused($focus, equals: field)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(identifier)
                Text(units.distanceUnit).font(.subheadline.weight(.medium)).foregroundStyle(ScreenKit.secondary)
            }
            .padding(.horizontal, 16).frame(minHeight: 56)
            .background(ScreenKit.card, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(valid ? ScreenKit.hairline : ScreenKit.red, lineWidth: 1))
            .contentShape(.rect)
            .onTapGesture { focus = field }
            Text(valid ? caption : "Enter a whole number below 10,000,000.")
                .font(.caption).foregroundStyle(valid ? ScreenKit.tertiary : ScreenKit.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Populated") {
    NavigationStack { LeaseMileageView() }.voltaPreviewEnvironment()
}

#Preview("Empty") {
    NavigationStack { LeaseMileageView() }.voltaPreviewEnvironment(empty: true)
}
