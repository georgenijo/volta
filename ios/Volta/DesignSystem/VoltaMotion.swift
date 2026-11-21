import SwiftUI

// Volta's motion vocabulary. Every animation in the app uses one of these
// springs, so things move the same way everywhere, and every helper here
// turns itself off (or into a plain fade) under Reduce Motion.
// See DesignSystem/README.md "Design rules".

enum VoltaMotion {
    /// Quick response to a touch: toggles, presses, selection, a digit rolling.
    static let snappy = Animation.spring(duration: 0.3, bounce: 0.15)
    /// A reading settling: gauges, bars and markers gliding to their value.
    static let settle = Animation.spring(duration: 0.8, bounce: 0.2)
    /// Content arriving: cards and rows coming into focus.
    static let arrive = Animation.spring(duration: 0.55, bounce: 0.12)
    /// A small reward with some bounce: a command confirmed, a limit reached.
    static let pop = Animation.spring(duration: 0.4, bounce: 0.45)
    /// Gap between items of a staggered entrance.
    static let stagger: Double = 0.05
    /// Items past this index arrive without waiting their turn, so a long
    /// list never makes people wait for its tail.
    static let maxStaggered = 8

    /// `animation`, or nil under Reduce Motion.
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - Focus in

/// Content comes into focus as it appears: from blurred, slightly small and
/// clear to sharp. `index` staggers siblings so they arrive in order.
/// Under Reduce Motion it is a short fade with no blur or scale.
///
///     ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
///         RowView(row).voltaFocusIn(i)
///     }
private struct FocusIn: ViewModifier {
    var index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduceMotion ? 0 : 10)
            .scaleEffect(shown || reduceMotion ? 1 : 0.96)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    withAnimation(.easeOut(duration: 0.2)) { shown = true }
                } else {
                    let delay = Double(min(max(index, 0), VoltaMotion.maxStaggered)) * VoltaMotion.stagger
                    withAnimation(VoltaMotion.arrive.delay(index > VoltaMotion.maxStaggered ? 0 : delay)) { shown = true }
                }
            }
    }
}

extension View {
    /// See `FocusIn`: this view comes into focus when it appears.
    func voltaFocusIn(_ index: Int = 0) -> some View { modifier(FocusIn(index: index)) }
}

// MARK: - Rolling numbers

/// A number whose digits roll: up from zero when it first appears, and from
/// the old value to the new one whenever it changes. Under Reduce Motion the
/// final value shows at once.
///
///     RollingNumber(value: 231) { VoltaFormat.number($0, digits: 0) }
///         .font(.system(size: 34, weight: .bold))
struct RollingNumber: View {
    var value: Double
    var format: (Double) -> String
    /// Roll up from zero on first appearance (true) or start at the value.
    var rollsIn = true

    @State private var shown: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let current = shown ?? (rollsIn && !reduceMotion ? 0 : value)
        Text(format(current))
            .monospacedDigit()
            .contentTransition(.numericText(value: current))
            .accessibilityLabel(format(value))
            .onAppear {
                guard shown == nil else { return }
                if reduceMotion || !rollsIn {
                    shown = value
                } else {
                    shown = 0
                    withAnimation(VoltaMotion.settle.delay(0.1)) { shown = value }
                }
            }
            .onChange(of: value) { _, new in
                withAnimation(VoltaMotion.animation(VoltaMotion.snappy, reduceMotion: reduceMotion)) { shown = new }
            }
    }
}

extension View {
    /// Text that rolls its digits when `value` changes. Use on a `Text`
    /// showing a number that updates in place (a live reading, a stepper).
    func voltaRolling<V: Equatable>(_ value: V) -> some View {
        modifier(Rolling(value: value))
    }
}

private struct Rolling<V: Equatable>: ViewModifier {
    var value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(VoltaMotion.animation(VoltaMotion.snappy, reduceMotion: reduceMotion), value: value)
    }
}

#Preview("Motion") {
    struct Demo: View {
        @State private var value = 231.0
        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                RollingNumber(value: value) { VoltaFormat.number($0, digits: 0) }
                    .font(.system(size: 48, weight: .heavy))
                    .foregroundStyle(Color.voltaTextPrimary)
                Button("Change") { value = Double(Int.random(in: 100...400)) }
                ForEach(0..<4) { i in
                    Card { Text("Card \(i + 1)").foregroundStyle(Color.voltaTextPrimary) }
                        .voltaFocusIn(i)
                }
            }
            .padding(VoltaSpacing.screen)
        }
    }
    return Demo().voltaScreenBackground()
}
