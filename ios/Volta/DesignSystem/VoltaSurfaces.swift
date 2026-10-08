import SwiftUI

// MARK: - Card

/// Rounded card surface: `#17191C` fill, 1px hairline border, 20pt radius.
///
///     Card { Text("Hello") }
///     Card(padding: 0) { ... }   // edge-to-edge content
struct Card<Content: View>: View {
    var padding: CGFloat = VoltaSpacing.lg
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .voltaCardBackground(tint: tint)
    }
}

extension View {
    /// Card fill + hairline border without the padding/frame of `Card`.
    /// `tint` adds a faint radial glow (e.g. amber for a "warm" metric).
    func voltaCardBackground(tint: Color? = nil, radius: CGFloat = VoltaRadius.card) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.voltaCard)
                .overlay {
                    if let tint {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(
                                RadialGradient(
                                    colors: [tint.opacity(0.16), .clear],
                                    center: .bottom, startRadius: 0, endRadius: 180
                                )
                            )
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.voltaHairline, lineWidth: 1)
                }
        }
    }
}

// MARK: - SectionLabel

/// Small-caps gray section label, optionally followed by a hairline rule and
/// trailing text, like "ACCESS ───────── 5 controls".
///
///     SectionLabel("Last 48h")
///     SectionLabel("Access", trailing: "5 controls", rule: true)
struct SectionLabel<Trailing: View>: View {
    var title: String
    var rule: Bool
    var trailing: Trailing

    init(_ title: String, rule: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.rule = rule
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: VoltaSpacing.md) {
            Text(title)
                .voltaLabelStyle()
                .accessibilityAddTraits(.isHeader)
            if rule {
                Rectangle().fill(Color.voltaHairline).frame(height: 1)
            } else {
                Spacer(minLength: VoltaSpacing.sm)
            }
            trailing
        }
    }
}

extension SectionLabel where Trailing == AnyView {
    init(_ title: String, trailing: String? = nil, rule: Bool = false) {
        self.title = title
        self.rule = rule
        if let trailing {
            self.trailing = AnyView(
                Text(trailing)
                    .font(.footnote)
                    .foregroundStyle(Color.voltaTextTertiary)
            )
        } else {
            self.trailing = AnyView(EmptyView())
        }
    }
}

// MARK: - Hairline divider

/// 1px divider in the hairline color. `leadingInset` indents it past a row icon.
struct HairlineDivider: View {
    var leadingInset: CGFloat = 0
    var body: some View {
        Rectangle()
            .fill(Color.voltaHairline)
            .frame(height: 1)
            .padding(.leading, leadingInset)
    }
}

// MARK: - StatusDot

/// Small colored dot used in legends and status lines ("● Online").
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

// MARK: - EmptyState

/// Thin-line icon, bold title, one gray line. Left-aligned like the references.
///
///     EmptyState(systemImage: "bolt.slash", title: "No charges in 30 days",
///                message: "Try a different range or wait for your next charge.")
struct EmptyState: View {
    var systemImage: String
    var title: String
    var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(Color.voltaTextTertiary)
                .padding(.bottom, VoltaSpacing.sm)
            Text(title)
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(Color.voltaTextPrimary)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.voltaTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VoltaSpacing.xl + VoltaSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - InlineBanner

/// Compact rounded banner for transient notices and errors
/// (e.g. "Vehicle commands aren't connected yet.").
struct InlineBanner: View {
    var systemImage: String = "info.circle"
    var message: String
    var tint: Color = .voltaAmber
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: VoltaSpacing.md) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.voltaTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.voltaTextSecondary)
                }
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, VoltaSpacing.lg)
        .padding(.vertical, VoltaSpacing.md)
        .background {
            RoundedRectangle(cornerRadius: VoltaRadius.control, style: .continuous)
                .fill(tint.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: VoltaRadius.control, style: .continuous)
                        .strokeBorder(tint.opacity(0.3), lineWidth: 1)
                }
        }
    }
}

#Preview("Surfaces") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            SectionLabel("Last 48h")
            SectionLabel("Access", trailing: "5 controls", rule: true)
            Card { Text("Card content").foregroundStyle(.white) }
            Card(tint: .voltaAmber) { Text("Warm card").foregroundStyle(.white) }
            InlineBanner(systemImage: "lock.slash", message: "Vehicle commands aren't connected yet.", onDismiss: {})
            HStack { StatusDot(color: .voltaGreen); Text("Online").foregroundStyle(Color.voltaTextSecondary) }
            EmptyState(systemImage: "bolt.slash", title: "No charges in 30 days",
                       message: "Try a different range or wait for your next charge.")
        }
        .padding(VoltaSpacing.screen)
    }
    .voltaScreenBackground()
    .preferredColorScheme(.dark)
}
