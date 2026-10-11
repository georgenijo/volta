import SwiftUI

/// "Electricity rate" form: a home rate and an optional Supercharger / DC fast
/// rate, used only for sessions the server didn't price. Saved on this device.
struct ElectricityRateSheet: View {
    var rates: ElectricityRates
    var onSave: (_ home: Double?, _ dcFast: Double?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var homeText = ""
    @State private var dcText = ""
    @FocusState private var focus: Field?

    private enum Field { case home, dc }

    private var symbol: String { ElectricityRates.symbol(for: rates.currency) }
    private var home: ElectricityRates.Input { Self.input(homeText, saved: rates.home, currency: rates.currency) }
    private var dc: ElectricityRates.Input { Self.input(dcText, saved: rates.dcFast, currency: rates.currency) }
    private var canSave: Bool { home != .invalid && dc != .invalid }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Used to estimate costs for charging sessions your server didn't price. Prices recorded on the server always win.")
                        .font(.system(size: 14)).foregroundStyle(ScreenKit.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("screen.electricity-rate")
                    field("Home (\(symbol)/kWh)", text: $homeText, prompt: "0.15", input: home, field: .home,
                          caption: "Home and other AC charging.", identifier: "field.rate.home")
                    field("Supercharger / DC fast (\(symbol)/kWh)", text: $dcText, prompt: "Same as home", input: dc, field: .dc,
                          caption: "Leave blank to use your home rate.", identifier: "field.rate.dc")
                    Text("Enter 0 if charging is free. Currency follows Settings › General.")
                        .font(.system(size: 12)).foregroundStyle(ScreenKit.tertiary)
                }
                .padding(.horizontal, ScreenKit.horizontalPadding)
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(ScreenKit.background.ignoresSafeArea())
            .navigationTitle("Electricity rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ScreenKit.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("button.rate.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                        .accessibilityIdentifier("button.rate.save")
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationBackground(ScreenKit.background)
        .onAppear {
            homeText = Self.text(rates.home)
            dcText = Self.text(rates.dcFast)
            if rates.home == nil { focus = .home }
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, input: ElectricityRates.Input,
                       field: Field, caption: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ScreenKit.secondary)
            HStack(spacing: 6) {
                Text(symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(ScreenKit.secondary)
                TextField(prompt, text: text)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .focused($focus, equals: field)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(identifier)
                Text("/kWh").font(.system(size: 15, weight: .medium)).foregroundStyle(ScreenKit.secondary)
            }
            .padding(.horizontal, 16).frame(height: 56)
            .background(ScreenKit.card, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(input == .invalid ? ScreenKit.red : ScreenKit.hairline, lineWidth: 1))
            .contentShape(.rect)
            .onTapGesture { focus = field }
            Text(input == .invalid ? "Enter a price from 0 to \(VoltaFormat.money(ElectricityRates.maximum, currency: rates.currency)) per kWh." : caption)
                .font(.system(size: 12)).foregroundStyle(input == .invalid ? ScreenKit.red : ScreenKit.tertiary)
        }
    }

    private func save() {
        guard canSave else { return }
        func value(_ input: ElectricityRates.Input) -> Double? { if case .valid(let v) = input { v } else { nil } }
        onSave(value(home), value(dc))
        dismiss()
    }

    /// The saved rate as editable text, without rounding it to a display precision.
    static func text(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...10)).grouping(.never).locale(Locale(identifier: "en_US_POSIX"))) } ?? ""
    }

    /// A field left as prefilled saves the saved value exactly; anything typed is parsed.
    static func input(_ text: String, saved: Double?, currency: String) -> ElectricityRates.Input {
        if let saved, text == Self.text(saved) { return .valid(saved) }
        return ElectricityRates.input(text, currency: currency)
    }
}

extension View {
    /// Presents the electricity rate form and writes the result to settings;
    /// costs that depend on it recompute as soon as it saves.
    func electricityRateSheet(isPresented: Binding<Bool>, settings: UserSettings?) -> some View {
        sheet(isPresented: isPresented) {
            if let settings {
                ElectricityRateSheet(rates: settings.rates) { home, dcFast in
                    settings.electricityRate = home
                    settings.dcFastRate = dcFast
                }
            }
        }
    }
}

/// "—" plus a tappable "Set rate", for costs that need a rate the user hasn't given.
struct SetRateButton: View {
    var settings: UserSettings?
    var size: CGFloat = 13
    /// Plain blue text instead of a tinted capsule.
    var link = false
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            Text("Set rate")
                .font(.system(size: size, weight: link ? .medium : .semibold))
                .foregroundStyle(ScreenKit.blue)
                .padding(.horizontal, link ? 0 : 10).padding(.vertical, link ? 0 : 5)
                .background(ScreenKit.blue.opacity(link ? 0 : 0.14), in: .capsule)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("button.rate.set")
        .electricityRateSheet(isPresented: $editing, settings: settings)
    }
}

#Preview("Electricity rate") {
    Color.black.sheet(isPresented: .constant(true)) {
        ElectricityRateSheet(rates: ElectricityRates(home: 0.15, dcFast: nil, currency: "USD")) { _, _ in }
    }
}
