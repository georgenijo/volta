import SwiftUI

// Layout helpers for windows of different shapes: ordinary iPhones, and the
// outer and inner displays of iPhone Duo. Screens branch on size classes and
// on these values, never on a device model or a screen size.

extension EnvironmentValues {
    /// True when the system has moved the tab bar and toolbars to the side of
    /// the window, as on iPhone Duo's outer display and its inner display
    /// opened flat. Titles that would otherwise sit in the navigation bar
    /// belong in the content then, because a title keeps a horizontal bar alive.
    @Entry var barsOnSide = false
}

extension View {
    /// Publishes `\.barsOnSide` to this view from its own safe area.
    func readsBarsOnSide() -> some View { modifier(BarsOnSideReader()) }

    /// Caps long scrolling content at a readable width and centers it, so
    /// rows and cards do not stretch across a regular-width window.
    func voltaReadableWidth(_ maxWidth: CGFloat = VoltaLayout.readableWidth) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }
}

enum VoltaLayout {
    /// Widest a single column of rows or cards should grow.
    static let readableWidth: CGFloat = 640

    /// Side bars reserve one horizontal edge only. A notch in landscape
    /// insets both edges equally, so the difference tells them apart.
    static func barsOnSide(leading: CGFloat, trailing: CGFloat) -> Bool {
        abs(leading - trailing) >= 60
    }
}

private struct BarsOnSideReader: ViewModifier {
    @State private var onSide = false

    func body(content: Content) -> some View {
        content
            .environment(\.barsOnSide, onSide)
            .onGeometryChange(for: Bool.self) { proxy in
                VoltaLayout.barsOnSide(leading: proxy.safeAreaInsets.leading, trailing: proxy.safeAreaInsets.trailing)
            } action: { onSide = $0 }
    }
}

/// Two panes that share a regular-width window: side by side when the window
/// is wider than it is tall. On iPhone Duo the system keeps each pane clear of
/// the fold and gives each one a side when the device is partly folded.
/// Navigation containers go around this view, not inside it.
struct VoltaPanes<Primary: View, Secondary: View>: View {
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary

    var body: some View {
        // `ArrangementView` is in the iOS 27.1 SDK. Xcode 27.2 (Swift 6.4.2)
        // is known to have it; older toolchains, such as CI's, build the
        // plain layout only.
        #if compiler(>=6.4.2)
        if #available(iOS 27.1, *) {
            ArrangementView { primary } secondary: { secondary }
                .arrangementViewStyle(.split.axes(.horizontal))
        } else {
            sideBySide
        }
        #else
        sideBySide
        #endif
    }

    private var sideBySide: some View {
        HStack(spacing: 0) {
            primary.frame(maxWidth: .infinity)
            secondary.frame(maxWidth: .infinity)
        }
    }
}
