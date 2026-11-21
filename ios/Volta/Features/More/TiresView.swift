import SwiftUI

struct TiresView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var state: Loadable<VehicleStatus> = .loading
    @State private var generation = 0
    /// Counts pulls to refresh that brought a reading, for the refresh haptic.
    @State private var refreshed = 0

    var body: some View {
        ScreenKit.Page(scroll: "tires") {
            LoadableContent(state: state, retry: { await load() }, errorTitle: "Couldn't load tire pressures") { status in
                VStack(spacing: 24) {
                    if let freshness = status.telemetryFreshness {
                        Text(freshness.label).font(.caption).foregroundStyle(Color.voltaTextSecondary)
                    }
                    Card(padding: 20) {
                        // Readings sit beside the car's wheels; the car scales
                        // with the card instead of fixing the row's width.
                        HStack(spacing: 12) {
                            VStack {
                                tire("Front left", reading: status.tpms?.fl)
                                Spacer(minLength: 24)
                                tire("Rear left", reading: status.tpms?.rl)
                            }
                            carOutline
                                .aspectRatio(110 / 250, contentMode: .fit)
                                .frame(maxWidth: 120)
                            VStack {
                                tire("Front right", reading: status.tpms?.fr)
                                Spacer(minLength: 24)
                                tire("Rear right", reading: status.tpms?.rr)
                            }
                        }
                        .frame(height: 280)
                    }
                    .voltaFocusIn(0)
                    if [status.tpms?.fl.pressureBar, status.tpms?.fr.pressureBar,
                        status.tpms?.rl.pressureBar, status.tpms?.rr.pressureBar].allSatisfy({ $0 == nil }) {
                        Text("No tire pressure yet. Readings stream while the car is awake.")
                            .font(.subheadline).foregroundStyle(Color.voltaTextSecondary)
                    }
                    Text("Amber marks readings below 2.5 bar (36 psi). Check the door placard for your vehicle’s recommended cold pressure. This guide is not a vehicle TPMS warning.")
                        .font(.footnote).foregroundStyle(Color.voltaTextSecondary)
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("screen.tires")
            }
            // History and the rotation reminder load on their own, so they
            // show even when no current reading is available.
            VStack(spacing: 24) {
                TireHistorySection()
                TireRotationRow()
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .screenKitPage("Tires")
        .task(id: vehicleID) { state = .loading; await load() }
        .refreshable { if await load() { refreshed += 1 } }
        .voltaFeedback(.refreshed, trigger: refreshed)
    }

    private var carOutline: some View {
        RoundedRectangle(cornerRadius: 36)
            .fill(Color.voltaRaised)
            .overlay { RoundedRectangle(cornerRadius: 36).stroke(Color.voltaTextTertiary, lineWidth: 2) }
            .overlay {
                // Windshield, roof and rear window in the original 250 pt proportions.
                GeometryReader { proxy in
                    let unit = proxy.size.height / 250
                    VStack(spacing: 16 * unit) {
                        RoundedRectangle(cornerRadius: 14 * unit).fill(Color.voltaBackground).frame(height: 42 * unit)
                        RoundedRectangle(cornerRadius: 12 * unit).stroke(Color.voltaHairline).frame(height: 75 * unit)
                        RoundedRectangle(cornerRadius: 12 * unit).fill(Color.voltaBackground).frame(height: 35 * unit)
                    }
                    .padding(15 * unit)
                }
            }
            .accessibilityHidden(true)
    }

    private func tire(_ title: String, reading: TireReading?) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption.weight(.medium))
            ScreenKit.RollingNumeral(value: reading?.pressureBar.map { units.pressureValue(bar: $0) },
                                     digits: units.pressure == .bar ? 1 : 0, size: 30, weight: .semibold,
                                     color: reading?.isLow == true ? Color.voltaAmber : Color.voltaTextPrimary)
            Text(reading?.isLow == true ? "\(units.pressureUnit) · low" : units.pressureUnit).font(.caption)
                .foregroundStyle(reading?.isLow == true ? Color.voltaAmber : Color.voltaTextSecondary)
            if let date = reading?.updatedAt {
                Text("As of \(VoltaFormat.dateTime(date))")
                    .font(.caption2).multilineTextAlignment(.center)
            } else { Text("Not recorded").font(.caption2) }
        }
        .foregroundStyle(Color.voltaTextSecondary)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// True when a reading loaded.
    @discardableResult
    private func load() async -> Bool {
        generation += 1
        let token = generation
        do {
            let status = try await dataSource.status(vehicleID: vehicleID)
            guard token == generation, !Task.isCancelled else { return false }
            state = .loaded(status)
            return true
        } catch {
            guard token == generation, !Task.isCancelled else { return false }
            state = .failed(error.localizedDescription)
            return false
        }
    }
}

#Preview { NavigationStack { TiresView().voltaPreviewEnvironment() } }
