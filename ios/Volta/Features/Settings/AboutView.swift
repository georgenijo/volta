import SwiftUI

/// Support & About: version, privacy, how the pieces fit together.
struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 10) {
                    SettingsWordmark(height: 30)
                    Text("Your Tesla, your server.").font(.system(size: 15, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)

                ScreenKit.GroupCard(title: "About") {
                    ScreenKit.ValueRow(title: "Version") {
                        Text("\(AppInfo.version) (\(AppInfo.build))").font(.system(size: 15, design: .monospaced)).foregroundStyle(ScreenKit.secondary)
                    }
                    ScreenKit.ValueRow(title: "Data", subtitle: "Collected by TeslaMate, served by volta-api") {
                        Image(systemName: "server.rack").foregroundStyle(ScreenKit.mint)
                    }
                    ScreenKit.ValueRow(title: "Privacy", subtitle: "Your data stays on your server. No analytics, no third parties.", showsDivider: false) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(ScreenKit.mint)
                    }
                }
                ScreenKit.GroupCard(title: "Help", footer: "Volta is not affiliated with, endorsed by, or sponsored by Tesla, Inc.") {
                    Link(destination: URL(string: "https://github.com/georgenijo/volta")!) {
                        ScreenKit.ValueRow(title: "Project on GitHub", subtitle: "Docs, issues and server setup") {
                            Image(systemName: "arrow.up.right").foregroundStyle(ScreenKit.secondary)
                        }
                    }
                    Link(destination: URL(string: "https://docs.teslamate.org")!) {
                        ScreenKit.ValueRow(title: "TeslaMate docs", subtitle: "Geofences, costs and data collection", showsDivider: false) {
                            Image(systemName: "arrow.up.right").foregroundStyle(ScreenKit.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage("Support")
    }
}

#Preview { NavigationStack { AboutView() }.voltaPreviewEnvironment() }
