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
struct TeslaSignInPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tesla = model.tesla
        VStack(spacing: 14) {
            switch tesla.state {
            case .idle, .loading:
                ProgressView()
            case .notAvailable:
                Text("Sign in with Tesla isn't set up on your server yet.")
                    .font(.subheadline).foregroundStyle(Color.voltaTextSecondary)
            case .connected:
                ProgressView()
                Text("Tesla account connected. Your server's collector is discovering your vehicle — this can take a few minutes.")
                    .font(.subheadline).foregroundStyle(Color.voltaTextSecondary)
                if tesla.status?.budget?.paused == true {
                    InlineBanner(systemImage: "pause.circle", message: "Data collection is paused: this month's Tesla API budget is used up.")
                }
            default:
                if let message = tesla.failureMessage {
                    InlineBanner(systemImage: "exclamationmark.triangle", message: message)
                }
                TeslaSignInButton(tesla: tesla)
                Text(TeslaLinkModel.scopeDisclosure)
                    .font(.footnote).foregroundStyle(Color.voltaTextSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, VoltaSpacing.screen)
        .task { await model.refreshTesla() }
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
                        StatusDot(color: statusColor(tesla))
                        Text(statusText(tesla)).font(.system(size: 15)).foregroundStyle(ScreenKit.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("row.teslaStatus")
                if showsCollection(tesla), let status = tesla.status {
                    ScreenKit.ValueRow(title: "Data collection", subtitle: budgetText(status), showsDivider: false) {
                        Text(collectionText(status)).font(.system(size: 15))
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
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ScreenKit.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .voltaCardBackground(radius: VoltaRadius.wideButton)
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
        case .connected: tesla.status?.budget?.paused == true ? ScreenKit.amber : ScreenKit.green
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
