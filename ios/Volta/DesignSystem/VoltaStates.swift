import SwiftUI

// Loading, empty and error states. A screen is never blank: while it loads
// it shows its own layout as a shimmering skeleton, and when there is
// nothing to show it says why and offers the next step.
// See DesignSystem/README.md "Design rules".

// MARK: - Skeleton

/// Draws the content as grey placeholder shapes with a slow sweep of light
/// while `active`. Apply it to the real layout filled with sample values, so
/// the skeleton has the shape of what is coming. Under Reduce Motion the
/// shapes stay still.
///
///     DriveRow(.sample).voltaSkeleton(model.isLoading)
private struct Skeleton: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active {
            content
                .redacted(reason: .placeholder)
                .overlay { if !reduceMotion { SkeletonSweep().mask(content.redacted(reason: .placeholder)) } }
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading")
                .transition(.opacity)
        } else {
            content
        }
    }
}

private struct SkeletonSweep: View {
    @State private var running = false

    var body: some View {
        GeometryReader { geo in
            let band = max(geo.size.width * 0.5, 80)
            LinearGradient(colors: [.clear, Color.voltaInk.opacity(0.12), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: running ? geo.size.width : -band)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { running = true }
        }
    }
}

extension View {
    /// See `Skeleton`: placeholder shapes with a sweep of light while `active`.
    func voltaSkeleton(_ active: Bool) -> some View { modifier(Skeleton(active: active)) }
}

// MARK: - Empty and error states

/// Icon, title, one line of explanation, and the next step as a button when
/// there is one. The icon gives a small bounce as the state appears.
///
///     EmptyState(systemImage: "bolt.slash", title: "No charges in 30 days",
///                message: "Charges appear here after your next session.")
///     EmptyState(systemImage: "car", title: "No drives yet", message: "…",
///                action: .init("Show all time", systemImage: "calendar") { range = .all })
struct EmptyState: View {
    struct Action {
        var title: String
        var systemImage: String?
        var handler: () -> Void
        init(_ title: String, systemImage: String? = nil, handler: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.handler = handler
        }
    }

    var systemImage: String
    var title: String
    var message: String?
    var tint: Color = .voltaTextTertiary
    var action: Action?

    @State private var appeared = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(systemImage: String, title: String, message: String? = nil,
         tint: Color = .voltaTextTertiary, action: Action? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.tint = tint
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: appeared)
                .padding(.bottom, VoltaSpacing.sm)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(Color.voltaTextPrimary)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.voltaTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                PillButton(action.title, systemImage: action.systemImage, style: .accent, action: action.handler)
                    .fixedSize()
                    .padding(.top, VoltaSpacing.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VoltaSpacing.xl + VoltaSpacing.xs)
        .accessibilityElement(children: .contain)
        .voltaFocusIn()
        .onAppear { if !reduceMotion { appeared += 1 } }
    }
}

/// A load that failed: what went wrong, and Try again.
///
///     ErrorState(title: "Couldn't load drives", message: error.localizedDescription) { await reload() }
struct ErrorState: View {
    var title: String
    var message: String?
    var retry: () async -> Void

    @State private var retrying = false

    var body: some View {
        EmptyState(systemImage: "wifi.exclamationmark", title: title, message: message, tint: .voltaAmber,
                   action: .init(retrying ? "Trying…" : "Try again", systemImage: "arrow.clockwise") {
            guard !retrying else { return }
            retrying = true
            Task {
                await retry()
                retrying = false
            }
        })
        .voltaFeedback(trigger: retrying) { old, new in old && !new ? .refreshed : nil }
    }
}

#Preview("States") {
    ScrollView {
        VStack(alignment: .leading, spacing: 32) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Loading drive").font(.headline)
                    Text("12.4 mi · 23 min · 241 Wh/mi").font(.subheadline)
                }
            }
            .voltaSkeleton(true)
            EmptyState(systemImage: "bolt.slash", title: "No charges in 30 days",
                       message: "Charges appear here after your next session.",
                       action: .init("Show all time", systemImage: "calendar") {})
            ErrorState(title: "Couldn't load drives", message: "The server didn't answer.") {}
        }
        .padding(VoltaSpacing.screen)
    }
    .voltaScreenBackground()
}
