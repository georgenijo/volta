import SwiftUI

struct TiresView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var state: Loadable<VehicleStatus> = .loading
    @State private var generation = 0

    var body: some View {
        ScrollView {
            LoadableContent(state: state, retry: load) { status in
                VStack(spacing: 24) {
                    if let freshness = status.telemetryFreshness {
                        Text(freshness.label).font(.caption).foregroundStyle(Color.voltaTextSecondary)
                    }
                    Card(padding: 20) {
                        ZStack {
                            carOutline.frame(width: 110, height: 250)
                            HStack {
                                VStack(spacing: 100) {
                                    tire("Front left", reading: status.tpms?.fl)
                                    tire("Rear left", reading: status.tpms?.rl)
                                }
                                Spacer(minLength: 110)
                                VStack(spacing: 100) {
                                    tire("Front right", reading: status.tpms?.fr)
                                    tire("Rear right", reading: status.tpms?.rr)
                                }
                            }
                        }
                        .frame(minHeight: 320)
                    }
                    if [status.tpms?.fl.pressureBar, status.tpms?.fr.pressureBar,
                        status.tpms?.rl.pressureBar, status.tpms?.rr.pressureBar].allSatisfy({ $0 == nil }) {
                        Text("No valid tire pressure yet — streams when the car is awake")
                            .font(.subheadline).foregroundStyle(Color.voltaTextSecondary)
                    }
                    Text("Amber marks readings below 2.5 bar (36 psi). Check the door placard for your vehicle’s recommended cold pressure. This guide is not a vehicle TPMS warning.")
                        .font(.footnote).foregroundStyle(Color.voltaTextSecondary)
                }
                .accessibilityIdentifier("screen.tires")
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage("Tires")
        .task(id: vehicleID) { state = .loading; await load() }
        .refreshable { await load() }
    }

    private var carOutline: some View {
        RoundedRectangle(cornerRadius: 36)
            .fill(Color.voltaRaised)
            .overlay { RoundedRectangle(cornerRadius: 36).stroke(Color.voltaTextTertiary, lineWidth: 2) }
            .overlay {
                VStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 14).fill(Color.voltaBackground).frame(height: 42)
                    RoundedRectangle(cornerRadius: 12).stroke(Color.voltaHairline).frame(height: 75)
                    RoundedRectangle(cornerRadius: 12).fill(Color.voltaBackground).frame(height: 35)
                }.padding(15)
            }
            .accessibilityHidden(true)
    }

    private func tire(_ title: String, reading: TireReading?) -> some View {
        VStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1)
            Text(reading?.pressureBar.map { VoltaFormat.number(units.pressureValue(bar: $0), digits: units.pressure == .bar ? 1 : 0) } ?? "—")
                .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                .foregroundStyle(reading?.isLow == true ? Color.voltaAmber : Color.voltaTextPrimary)
            Text(units.pressureUnit).font(.caption)
            if let date = reading?.updatedAt {
                Text("As of \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10)).multilineTextAlignment(.center)
            } else { Text("Not recorded").font(.system(size: 10)) }
        }
        .foregroundStyle(Color.voltaTextSecondary)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        generation += 1
        let token = generation
        do {
            let status = try await dataSource.status(vehicleID: vehicleID)
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(status)
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

#Preview { NavigationStack { TiresView().voltaPreviewEnvironment() } }
