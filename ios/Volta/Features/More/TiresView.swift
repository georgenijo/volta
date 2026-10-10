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
                VStack(alignment: .leading, spacing: 0) {
                    if let freshness = status.telemetryFreshness {
                        HStack(spacing: 8) {
                            Circle().fill(freshness.connected ? Color.voltaMint : Color.voltaTextTertiary)
                                .frame(width: 5, height: 5)
                                .shadow(color: freshness.connected ? Color.voltaMint.opacity(0.9) : .clear, radius: 3)
                            Text(freshness.label)
                                .font(.system(size: 11, weight: .semibold)).tracking(1).textCase(.uppercase)
                                .foregroundStyle(Color.voltaTextTertiary)
                        }
                        .accessibilityElement(children: .combine)
                        .padding(.top, 8)
                    }
                    ZStack {
                        TireCarOutline(tones: [tone(status.tpms?.fl), tone(status.tpms?.fr),
                                               tone(status.tpms?.rl), tone(status.tpms?.rr)])
                            .frame(width: 128, height: 286)
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 0) {
                                tire("Front left", reading: status.tpms?.fl, alignment: .leading)
                                Spacer(minLength: 0)
                                tire("Rear left", reading: status.tpms?.rl, alignment: .leading)
                            }
                            Spacer(minLength: 150)
                            VStack(alignment: .trailing, spacing: 0) {
                                tire("Front right", reading: status.tpms?.fr, alignment: .trailing)
                                Spacer(minLength: 0)
                                tire("Rear right", reading: status.tpms?.rr, alignment: .trailing)
                            }
                        }
                        .padding(.vertical, 26)
                    }
                    .frame(height: 340)
                    .padding(.top, 20)

                    HStack(spacing: 18) {
                        legend(Color.voltaMint, "In range")
                        legend(Color.voltaAmber, units.pressure == .bar ? "Below 2.5 bar" : "Below 36 psi")
                        legend(Color.voltaTextTertiary, "No reading")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 22)

                    if [status.tpms?.fl.pressureBar, status.tpms?.fr.pressureBar,
                        status.tpms?.rl.pressureBar, status.tpms?.rr.pressureBar].allSatisfy({ $0 == nil }) {
                        Text("No valid tire pressure yet — streams when the car is awake")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .padding(.top, 22)
                    }
                    Text("Amber marks readings below 2.5 bar (36 psi). Check the door placard for your vehicle’s recommended cold pressure. This guide is not a vehicle TPMS warning.")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.voltaTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.top, 28)
                }
                .accessibilityIdentifier("screen.tires")
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage("Tires")
        .voltaArrivalScope(isReady: state.isSettled)
        .task(id: vehicleID) { state = .loading; await load() }
        .refreshable { await load() }
    }

    private func tone(_ reading: TireReading?) -> Color {
        guard let reading, reading.pressureBar != nil else { return .voltaTextTertiary }
        return reading.isLow ? .voltaAmber : .voltaMint
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
                .shadow(color: color == .voltaTextTertiary ? .clear : color.opacity(0.9), radius: 3)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.voltaTextTertiary)
        }
    }

    private func tire(_ title: String, reading: TireReading?, alignment: HorizontalAlignment) -> some View {
        let value = reading?.pressureBar.map { VoltaFormat.number(units.pressureValue(bar: $0), digits: units.pressure == .bar ? 1 : 0) } ?? "—"
        let low = reading?.isLow == true
        return VStack(alignment: alignment, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(1.3)
                .foregroundStyle(Color.voltaTextTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                CountUpNumber(text: value)
                    .font(.system(size: 34, weight: .bold)).fontWidth(.expanded).tracking(-1)
                    .monospacedDigit()
                    .foregroundStyle(value == "—" ? AnyShapeStyle(Color.voltaTextTertiary)
                                     : low ? AnyShapeStyle(Color.voltaAmber)
                                     : AnyShapeStyle(LinearGradient(colors: [.white, .white.opacity(0.72)], startPoint: .top, endPoint: .bottom)))
                    .shadow(color: low ? Color.voltaAmber.opacity(0.55) : .clear, radius: 10)
                Text(units.pressureUnit).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
            }
            Group {
                if let date = reading?.updatedAt {
                    Text("As of \(VoltaFormat.dateTime(date))")
                } else { Text("Not recorded") }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.voltaTextTertiary)
            .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            .frame(maxWidth: 110, alignment: alignment == .leading ? .leading : .trailing)
        }
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

/// Minimal top-down car: a luminous hairline body with four glowing tire marks
/// (mint in range, amber low, tertiary when there's no reading).
private struct TireCarOutline: View {
    /// fl, fr, rl, rr
    var tones: [Color]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let shell = RoundedRectangle(cornerRadius: w * 0.42, style: .continuous)
            ZStack {
                shell
                    .fill(LinearGradient(colors: [Color.white.opacity(0.035), Color.white.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                shell
                    .stroke(Color.voltaBlue.opacity(0.35), lineWidth: 3)
                    .blur(radius: 8)
                shell
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.32), Color.white.opacity(0.1)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 1.25)
                // Glasshouse: windshield, roof and rear window as hairlines.
                RoundedRectangle(cornerRadius: w * 0.26, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    .frame(width: w * 0.7, height: h * 0.5)
                    .offset(y: h * 0.03)
                Path { p in
                    p.move(to: CGPoint(x: w * 0.17, y: h * 0.31))
                    p.addQuadCurve(to: CGPoint(x: w * 0.83, y: h * 0.31), control: CGPoint(x: w * 0.5, y: h * 0.24))
                    p.move(to: CGPoint(x: w * 0.2, y: h * 0.72))
                    p.addQuadCurve(to: CGPoint(x: w * 0.8, y: h * 0.72), control: CGPoint(x: w * 0.5, y: h * 0.77))
                }
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                // Headlights.
                HStack(spacing: w * 0.36) {
                    Capsule().fill(Color.white.opacity(0.5)).frame(width: w * 0.16, height: 2)
                    Capsule().fill(Color.white.opacity(0.5)).frame(width: w * 0.16, height: 2)
                }
                .shadow(color: .white.opacity(0.6), radius: 4)
                .position(x: w / 2, y: h * 0.045)
                ForEach(0..<4, id: \.self) { i in
                    let tint = tones.indices.contains(i) ? tones[i] : Color.voltaTextTertiary
                    let x = i % 2 == 0 ? -3 : w + 3
                    let y = i < 2 ? h * 0.2 : h * 0.8
                    Capsule()
                        .fill(tint.opacity(tint == .voltaTextTertiary ? 0.5 : 0.95))
                        .frame(width: 7, height: h * 0.13)
                        .shadow(color: tint == .voltaTextTertiary ? .clear : tint.opacity(0.9), radius: 4)
                        .shadow(color: tint == .voltaTextTertiary ? .clear : tint.opacity(0.45), radius: 12)
                        .position(x: x, y: y)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview { NavigationStack { TiresView().voltaPreviewEnvironment() } }
