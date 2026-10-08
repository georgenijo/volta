import SwiftUI

/// Placeholder for features scheduled after phase 1.
struct ComingLaterView: View {
    var feature: ComingLaterFeature

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                ZStack {
                    Circle().fill(ScreenKit.blue.opacity(0.10)).frame(width: 148, height: 148)
                    Circle().strokeBorder(ScreenKit.blue.opacity(0.18), lineWidth: 1).frame(width: 148, height: 148)
                    Circle().strokeBorder(ScreenKit.hairline, lineWidth: 1).frame(width: 210, height: 210)
                    Image(systemName: feature.symbol)
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(ScreenKit.blue)
                }
                .padding(.top, 48)

                VStack(spacing: 12) {
                    Text("COMING IN A LATER PHASE")
                        .font(.system(size: 11, weight: .semibold)).tracking(2)
                        .foregroundStyle(ScreenKit.secondary)
                    Text(feature.title)
                        .font(.system(size: 30, weight: .heavy)).tracking(-0.5)
                        .foregroundStyle(.white)
                    Text(feature.blurb)
                        .font(.system(size: 16))
                        .foregroundStyle(ScreenKit.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 36)

                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(ScreenKit.green)
                    Text("Built on your server, like everything else.")
                        .foregroundStyle(ScreenKit.secondary)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(ScreenKit.card, in: .capsule)
                .overlay(Capsule().strokeBorder(ScreenKit.hairline, lineWidth: 1))
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage(feature.title)
    }
}

#Preview {
    NavigationStack { ComingLaterView(feature: .automations) }
        .preferredColorScheme(.dark)
}
