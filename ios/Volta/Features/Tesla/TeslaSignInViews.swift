import SwiftUI

extension TeslaLinkModel {
    var buttonTitle: String {
        switch state {
        case .starting: "Opening Tesla…"
        case .awaitingTesla: "Waiting for Tesla…"
        case .completing: "Connecting…"
        case .needsReauth: "Reconnect Tesla"
        case .failed(_, true): "Try again"
        default: "Sign in with Tesla"
        }
    }
    var failureMessage: String? {
        if case .failed(let message, _) = state { return message }
        return nil
    }
    /// Retry a failure; otherwise start a new sign-in.
    func signIn() { if case .failed = state { retry() } else { start() } }
}

/// The primary button plus the scope disclosure.
private struct TeslaSignInButton: View {
    let tesla: TeslaLinkModel
    var body: some View {
        PillButton(tesla.buttonTitle, systemImage: "car.side", size: .wide, style: .accent, isBusy: tesla.isBusy) { tesla.signIn() }
            .disabled(!tesla.canSignIn)
            .accessibilityIdentifier("button.teslaSignIn")
    }
}

/// No-vehicle screen: connect a Tesla account, or wait for the collector.
/// Presented as a quiet lit hero: a glowing emblem, a short title, the
/// luminous sign-in button, and the scope disclosure.
struct TeslaSignInPanel: View {
    /// One quiet secondary line about why there's no vehicle yet.
    var note: String? = nil
    /// The latest vehicle-loading error; shown in every state, connected included.
    var error: String? = nil
    @Environment(AppModel.self) private var model

    /// The panel's secondary line. An error always shows and replaces the
    /// note; once connected the note is dropped because the panel already
    /// says the collector is discovering the vehicle.
    static func caption(state: TeslaLinkModel.State, note: String?, error: String?) -> String? {
        state == .connected ? error : error ?? note
    }

    var body: some View {
        let tesla = model.tesla
        let caption = Self.caption(state: tesla.state, note: note, error: error)
        VStack(spacing: 16) {
            switch tesla.state {
            case .idle, .loading:
                ProgressView().tint(Color.voltaTextSecondary)
            case .notAvailable:
                emblem(tint: .voltaTextTertiary, symbol: "car.side")
                Text("Sign in with Tesla isn't set up on your server yet.")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
                noteLine(caption)
            case .connected:
                emblem(tint: .voltaMint, symbol: "checkmark")
                ProgressView().tint(Color.voltaMint)
                Text("Tesla account connected. Your server's collector is discovering your vehicle — this can take a few minutes.")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
                if tesla.status?.budget?.paused == true {
                    InlineBanner(systemImage: "pause.circle", message: "Data collection is paused: this month's Tesla API budget is used up.")
                }
                if let caption {
                    InlineBanner(systemImage: "exclamationmark.triangle", message: caption)
                }
            default:
                emblem(tint: .voltaBlue, symbol: "car.side")
                    .padding(.bottom, 6)
                VStack(spacing: 6) {
                    Text("Tesla account")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.5).textCase(.uppercase)
                        .foregroundStyle(Color.voltaTextTertiary)
                    Text("Connect your Tesla")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.voltaTextPrimary)
                    noteLine(caption)
                        .padding(.top, 2)
                }
                if let message = tesla.failureMessage {
                    InlineBanner(systemImage: "exclamationmark.triangle", message: message)
                }
                TeslaSignInButton(tesla: tesla)
                    .padding(.top, 4)
                Text(TeslaLinkModel.scopeDisclosure)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.voltaTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background {
            RadialGradient(colors: [Color.voltaBlue.opacity(0.22), Color.voltaMint.opacity(0.05), .clear],
                           center: .init(x: 0.5, y: 0.12), startRadius: 0, endRadius: 240)
                .allowsHitTesting(false)
        }
        .voltaCardBackground(radius: 22)
        .padding(.horizontal, VoltaSpacing.screen)
        .task { await model.refreshTesla() }
    }

    @ViewBuilder private func noteLine(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func emblem(tint: Color, symbol: String) -> some View {
        ZStack {
            Circle().fill(tint.opacity(0.4)).blur(radius: 24).frame(width: 88, height: 88)
            Circle()
                .fill(LinearGradient(colors: [Color.voltaCardTop, Color.voltaCard], startPoint: .top, endPoint: .bottom))
            Circle()
                .strokeBorder(LinearGradient(colors: [tint.opacity(0.75), tint.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                              lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: tint.opacity(0.7), radius: 8)
        }
        .frame(width: 60, height: 60)
        .accessibilityHidden(true)
    }
}

/// Settings → Account: Tesla connection status, sign in, and disconnect.
struct TeslaAccountSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDisconnect = false

    var body: some View {
        let tesla = model.tesla
        VStack(alignment: .leading, spacing: 16) {
            ScreenKit.GroupCard(title: "Tesla account", footer: footer(tesla)) {
                ScreenKit.ValueRow(title: "Status", showsDivider: showsCollection(tesla)) {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor(tesla)).frame(width: 6, height: 6)
                            .shadow(color: statusColor(tesla).opacity(0.85), radius: 3)
                        Text(statusText(tesla)).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(statusColor(tesla) == ScreenKit.secondary ? ScreenKit.secondary : statusColor(tesla))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("row.teslaStatus")
                if showsCollection(tesla), let status = tesla.status {
                    ScreenKit.ValueRow(title: "Data collection", subtitle: budgetText(status), showsDivider: false) {
                        Text(collectionText(status)).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(status.budget?.paused == true ? ScreenKit.amber : ScreenKit.secondary)
                    }
                }
            }
            if let message = tesla.failureMessage ?? tesla.disconnectError {
                InlineBanner(systemImage: "exclamationmark.triangle", message: message, tint: ScreenKit.amber)
            }
            if tesla.canSignIn || tesla.isBusy {
                TeslaSignInButton(tesla: tesla)
            }
            if tesla.state == .connected || tesla.state == .needsReauth {
                Button(role: .destructive) { confirmDisconnect = true } label: {
                    HStack {
                        if tesla.isDisconnecting { ProgressView().tint(ScreenKit.red) } else { Image(systemName: "link.badge.minus") }
                        Text("Disconnect Tesla")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ScreenKit.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(ScreenKit.red.opacity(0.06), in: .rect(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(ScreenKit.red.opacity(0.22), lineWidth: 1)
                    }
                }
                .buttonStyle(VoltaPressStyle())
                .disabled(tesla.isDisconnecting)
                .accessibilityIdentifier("button.teslaDisconnect")
            }
        }
        .task(id: model.pairingState) { await model.refreshTesla() }
        .confirmationDialog("Disconnect your Tesla account?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect Tesla", role: .destructive) { Task { await tesla.disconnect() } }
        } message: {
            Text("Your server forgets its Tesla access and stops collecting new vehicle data. You can sign in again anytime.")
        }
    }

    private func showsCollection(_ tesla: TeslaLinkModel) -> Bool {
        (tesla.state == .connected || tesla.state == .needsReauth) && tesla.status != nil
    }
    private func statusText(_ tesla: TeslaLinkModel) -> String {
        switch tesla.state {
        case .idle, .loading: "Checking…"
        case .notAvailable: "Not set up on server"
        case .disconnected, .failed: "Not connected"
        case .needsReauth: "Reconnect needed"
        case .starting, .awaitingTesla, .completing: "Connecting…"
        case .connected: "Connected"
        }
    }
    private func statusColor(_ tesla: TeslaLinkModel) -> Color {
        switch tesla.state {
        case .connected: tesla.status?.budget?.paused == true ? ScreenKit.amber : ScreenKit.mint
        case .needsReauth: ScreenKit.amber
        default: ScreenKit.secondary
        }
    }
    private func collectionText(_ status: TeslaStatus) -> String {
        if status.budget?.paused == true { return "Paused" }
        return status.collector?.enabled == false ? "Off" : "On"
    }
    private func budgetText(_ status: TeslaStatus) -> String? {
        guard let budget = status.budget else { return nil }
        let spent = budget.spentUsd.formatted(.currency(code: "USD"))
        let limit = budget.monthlyLimitUsd.formatted(.currency(code: "USD"))
        return budget.paused ? "Monthly budget reached (\(spent) of \(limit))" : "\(spent) of \(limit) monthly budget"
    }
    private func footer(_ tesla: TeslaLinkModel) -> String {
        switch tesla.state {
        case .notAvailable: "Sign in with Tesla isn't set up on your server yet."
        case .needsReauth: "Tesla access expired or was revoked. Reconnect to resume collecting. " + TeslaLinkModel.scopeDisclosure
        default: TeslaLinkModel.scopeDisclosure
        }
    }
}
