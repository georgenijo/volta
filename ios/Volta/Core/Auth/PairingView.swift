import SwiftUI

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var serverURL = ""
    @State private var code = ""
    @State private var deviceName = "George’s iPhone"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Image(systemName: "bolt.shield.fill").font(.system(size: 52)).foregroundStyle(.blue).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text("VOLTA").font(.system(size: 38, weight: .heavy)).tracking(5)
                    Text("Your Tesla. Your server.").font(.title3).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 20) {
                    field("SERVER URL") {
                        TextField("https://your-server.tailnet.ts.net", text: $serverURL).keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    field("PAIRING CODE") {
                        TextField("8-character code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled().font(.body.monospaced())
                    }
                    field("DEVICE NAME") { TextField("Device name", text: $deviceName).textContentType(.name) }
                }.padding(24).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.08)))
                if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red).accessibilityLabel("Pairing error: \(error)") }
                Button {
                    Task { await model.pair(serverURL: serverURL, code: code, deviceName: deviceName) }
                } label: {
                    HStack { if model.isPairing { ProgressView().tint(.white) }; Text(model.isPairing ? "Pairing…" : "Pair this device").fontWeight(.semibold) }.frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent).disabled(model.isPairing || code.trimmingCharacters(in: .whitespacesAndNewlines).count != 8 || serverURL.isEmpty || deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Run the pairing command on your server to get a one-time code. It expires after 10 minutes.").font(.footnote).foregroundStyle(.secondary)
                Button("Try demo mode") { model.tryDemoMode() }.frame(maxWidth: .infinity).padding(.vertical, 8).disabled(model.isPairing)
            }.padding(28).padding(.top, 36).frame(maxWidth: 520)
        }.frame(maxWidth: .infinity).background(Color(red: 0.055, green: 0.059, blue: 0.067))
            .onAppear { serverURL = model.settings.serverURL }
            .scrollDismissesKeyboard(.interactively)
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            content().padding(12).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
