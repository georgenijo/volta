import SwiftUI

// Volta motion: restrained, meaningful, and always optional.
//
// Every primitive here renders its final state instantly when motion is off
// (Reduce Motion, or the `-VoltaDisableMotion` launch argument used by UI
// tests), and no repeating animation runs off screen, in a hidden tab, or
// while the scene is inactive.
//
//     .voltaArrivalScope()                        // once, on a screen root
//     CountUpNumber(km) { VoltaFormat.number($0, digits: 0) }   // hero numeral
//     SweepIn { p in Circle().trim(from: 0, to: 0.75 * value * p) ... }
//     stat.voltaArrival(delay: VoltaMotion.statDelay(i))        // stat strip
//     bar.voltaGrow(index: i)                     // 14-day rhythm bars
//     card.voltaCascade()                         // first ~6 list cards
//     dot.voltaLivePulse(color: c, isLive: driving)
//     CometPath(path: route, isActive: isNewest)
//     today.voltaBreathingGlow(color: .voltaMint)
//     EnergyFlow(shape: FlowLine(), fraction: 1, isActive: charging)
//     Text(score).voltaRollingNumber(Double(score))

// MARK: - Namespace

enum VoltaMotion {
    // Launch flag
    static let disableFlag = "-VoltaDisableMotion"

    /// True when `arguments` contain `-VoltaDisableMotion` (optionally followed by YES/1/true).
    static func disablesMotion(arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: disableFlag) else { return false }
        guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("-") else { return true }
        return !["no", "false", "0"].contains(arguments[index + 1].lowercased())
    }

    static let disabledByLaunchArgument = disablesMotion(arguments: ProcessInfo.processInfo.arguments)

    static func isEnabled(reduceMotion: Bool, flagEnabled: Bool) -> Bool { flagEnabled && !reduceMotion }

    // Durations (seconds)
    static let countUpDuration: Double = 0.9
    static let riseDuration: Double = 0.5
    static let enterDuration: Double = 0.6
    static let routeDrawDuration: Double = 1.4
    static let statStagger: Double = 0.08
    static let barStagger: Double = 0.04
    static let cardStagger: Double = 0.09
    /// Only the first cards visible when a screen appears cascade in.
    static let maxCascade = 6
    /// Views that first appear this long after a screen arrives render final state.
    static let arrivalWindow: TimeInterval = 1.2
    static let cometPeriod: Double = 3.4
    static let pulsePeriod: Double = 2.0
    static let pulseStagger: Double = 1.0
    static let pulseMaxScale: Double = 3.4
    static let breathePeriod: Double = 2.6
    static let flowPeriod: Double = 1.1

    // Curves
    /// Stat strip rise.
    static let rise = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: riseDuration)
    /// List card entrance.
    static let enter = Animation.timingCurve(0.2, 0.9, 0.25, 1, duration: enterDuration)
    /// Dials and arcs: a spring with a slight overshoot.
    static let sweep = Animation.spring(duration: 0.85, bounce: 0.18)
    /// Rhythm bars: springy, still restrained.
    static let grow = Animation.spring(duration: 0.6, bounce: 0.28)
    /// Count-up runs linearly; easing lives in `countUpValue`.
    static let countUp = Animation.linear(duration: countUpDuration)
    static let routeDraw = Animation.timingCurve(0.6, 0, 0.2, 1, duration: routeDrawDuration)
    static let press = Animation.spring(response: 0.28, dampingFraction: 0.7)
    static let roll = Animation.snappy(duration: 0.35)

    // Pure math (unit tested)

    static func easeOutQuart(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return 1 - pow(1 - t, 4)
    }

    /// Displayed count-up value at linear `progress` 0...1.
    static func countUpValue(_ target: Double, progress: Double) -> Double {
        progress >= 1 ? target : target * easeOutQuart(progress)
    }

    /// Entrance delay for the card at `index`, or nil when it should not animate.
    static func cascadeDelay(for index: Int) -> Double? {
        guard index >= 0, index < maxCascade else { return nil }
        return Double(index) * cardStagger
    }

    static func statDelay(_ index: Int) -> Double { Double(max(index, 0)) * statStagger }

    /// Glow bloom while an arc sweeps: 0 at rest, peaks mid-sweep.
    static func bloom(_ progress: Double) -> Double {
        max(0, sin(min(max(progress, 0), 1) * .pi))
    }

    private static let rippleCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0.6), endControlPoint: UnitPoint(x: 0.3, y: 1))
    private static let cometCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.45, y: 0), endControlPoint: UnitPoint(x: 0.2, y: 1))

    /// One expanding ring of the live pulse at `time`, delayed by `offset`.
    static func pulseRing(time: Double, offset: Double) -> (scale: Double, opacity: Double) {
        let local = time - offset
        guard local >= 0 else { return (1, 0) }
        let phase = local.truncatingRemainder(dividingBy: pulsePeriod) / pulsePeriod
        let eased = rippleCurve.value(at: phase)
        return (1 + (pulseMaxScale - 1) * eased, 0.7 * (1 - eased))
    }

    /// Comet position along the route (0...1) and its opacity, after the draw-on.
    static func comet(elapsed: Double) -> (fraction: Double, opacity: Double)? {
        let local = elapsed - routeDrawDuration
        guard local >= 0 else { return nil }
        let u = local.truncatingRemainder(dividingBy: cometPeriod) / cometPeriod
        let fraction = u < 0.6 ? cometCurve.value(at: u / 0.6) : 1
        let opacity: Double = switch u {
        case ..<0.08: u / 0.08
        case ..<0.52: 1
        case ..<0.62: 1 - (u - 0.52) / 0.1
        default: 0
        }
        return (fraction, opacity)
    }

    /// Breathing amount 0...1 with a `breathePeriod` cycle, starting at rest.
    static func breath(_ time: Double) -> Double {
        0.5 - 0.5 * cos(2 * .pi * time / breathePeriod)
    }

    /// Dash phase that moves flow pulses forward along their path.
    static func flowPhase(_ time: Double, spacing: Double) -> Double {
        let u = time.truncatingRemainder(dividingBy: flowPeriod) / flowPeriod
        return spacing * (1 - u)
    }

    /// A formatted number split into prefix, numeric value and suffix, so it can be
    /// re-rendered at intermediate values with the same shape.
    struct NumberTemplate: Equatable {
        var prefix: String
        var suffix: String
        var value: Double
        var fractionDigits: Int
        var grouped: Bool
        var locale: Locale

        init?(_ text: String, locale: Locale = .current) {
            let group = Character(locale.groupingSeparator ?? ",")
            let decimal = Character(locale.decimalSeparator ?? ".")
            let chars = Array(text)
            guard let start = chars.firstIndex(where: \.isWholeNumber) else { return nil }
            var end = start
            var digits = "", fraction = 0, grouped = false, inFraction = false
            while end < chars.count {
                let c = chars[end]
                if c.isWholeNumber {
                    digits.append(c); if inFraction { fraction += 1 }
                } else if c == group, !inFraction, end + 1 < chars.count, chars[end + 1].isWholeNumber {
                    grouped = true
                } else if c == decimal, !inFraction, end + 1 < chars.count, chars[end + 1].isWholeNumber {
                    inFraction = true; digits.append(".")
                } else { break }
                end += 1
            }
            let suffix = String(chars[end...])
            guard let value = Double(digits), !suffix.contains(where: \.isWholeNumber) else { return nil }
            self.prefix = String(chars[..<start])
            self.suffix = suffix
            self.value = value
            self.fractionDigits = fraction
            self.grouped = grouped
            self.locale = locale
        }

        func string(for value: Double) -> String {
            let number = value.formatted(.number.precision(.fractionLength(fractionDigits))
                .grouping(grouped ? .automatic : .never).locale(locale))
            return prefix + number + suffix
        }
    }

    /// Repeating animations run only when wanted, allowed, on screen, in the active tab and scene.
    static func shouldRun(isActive: Bool, motionAllowed: Bool, isVisible: Bool, isActiveTab: Bool, scenePhase: ScenePhase) -> Bool {
        isActive && motionAllowed && isVisible && isActiveTab && scenePhase == .active
    }

    /// Whether a view of `size` is inside its enclosing scroll view's visible bounds,
    /// expressed in the view's own coordinates. No scroll view means it is on screen.
    static func isInViewport(size: CGSize, scrollBounds: CGRect?) -> Bool {
        guard let scrollBounds else { return true }
        // Closed ranges, so a zero-size view (paused content collapses) still counts.
        return size.width >= scrollBounds.minX && scrollBounds.maxX >= 0
            && size.height >= scrollBounds.minY && scrollBounds.maxY >= 0
    }
}

// MARK: - Environment

extension EnvironmentValues {
    /// False under `-VoltaDisableMotion`; combine with Reduce Motion via `@VoltaMotionAllowed`.
    @Entry var voltaMotionEnabled: Bool = !VoltaMotion.disabledByLaunchArgument
    @Entry var voltaArrivalScope: VoltaArrivalScope? = nil
}

/// True when motion may play: the flag allows it and Reduce Motion is off.
@MainActor @propertyWrapper
struct VoltaMotionAllowed: DynamicProperty {
    @Environment(\.voltaMotionEnabled) private var flag
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init() {}
    var wrappedValue: Bool { VoltaMotion.isEnabled(reduceMotion: reduceMotion, flagEnabled: flag) }
}

// MARK: - Arrival scope

/// Tracks when a screen was freshly shown so its arrival motion plays then, and
/// not on data refreshes or when rows scroll in later.
@MainActor @Observable
final class VoltaArrivalScope {
    private(set) var generation = 1
    private(set) var arrivedAt: Date
    @ObservationIgnored private var slots = 0
    @ObservationIgnored private var hasAppeared = false

    init(now: Date = .now) { arrivedAt = now }

    /// A new arrival: every arrival view replays.
    func arrive(at date: Date = .now) {
        generation += 1
        arrivedAt = date
        slots = 0
    }

    /// First appearance: reuse the creation arrival unless the window lapsed.
    func appeared(at date: Date = .now) {
        guard !hasAppeared else { return }
        hasAppeared = true
        if !isOpen(at: date) { arrive(at: date) }
    }

    /// Content became ready late (first load): reopen the window without replaying what already played.
    func reopen(at date: Date = .now) {
        arrivedAt = date
    }

    func isOpen(at date: Date = .now) -> Bool {
        let age = date.timeIntervalSince(arrivedAt)
        return age >= 0 && age < VoltaMotion.arrivalWindow
    }

    /// Next cascade position in this arrival, or nil past `maxCascade`.
    func claimCascadeSlot() -> Int? {
        guard slots < VoltaMotion.maxCascade else { return nil }
        defer { slots += 1 }
        return slots
    }
}

private struct ArrivalScopeModifier: ViewModifier {
    var isReady: Bool
    @State private var scope = VoltaArrivalScope()
    @State private var readied = false
    @Environment(\.isActiveTab) private var isActiveTab

    func body(content: Content) -> some View {
        content
            .environment(\.voltaArrivalScope, scope)
            .onAppear {
                scope.appeared()
                readied = isReady
            }
            // Kept-alive tabs never disappear; a tab becoming active is a fresh showing.
            .onChange(of: isActiveTab) { _, active in
                if active { scope.arrive(); readied = isReady }
            }
            .onChange(of: isReady) { _, ready in
                guard ready, !readied else { return }
                readied = true
                scope.reopen()
            }
    }
}

extension View {
    /// Marks a screen root. Arrival motion inside replays when the screen is freshly
    /// shown (first appearance, tab re-selected). Pass `isReady: false` while the
    /// first load is pending so content that lands late still arrives.
    func voltaArrivalScope(isReady: Bool = true) -> some View {
        modifier(ArrivalScopeModifier(isReady: isReady))
    }
}

/// Drives arrival progress: 0 before arrival, animated to 1 on appear. Renders 1
/// immediately when motion is off, the arrival already played, or the view first
/// appears outside its scope's arrival window (scrolled in later, data refresh).
struct VoltaArrivalReader<Content: View>: View {
    enum Timing { case delay(Double), cascade(Int?) }

    var animation: Animation
    var timing: Timing
    var content: (Double) -> Content
    @Environment(\.voltaArrivalScope) private var scope
    @VoltaMotionAllowed private var motionAllowed
    @State private var playedGeneration: Int?
    @State private var isVisible = false

    init(animation: Animation, timing: Timing = .delay(0), @ViewBuilder content: @escaping (Double) -> Content) {
        self.animation = animation
        self.timing = timing
        self.content = content
    }

    private var generation: Int { scope?.generation ?? 0 }
    private var isPending: Bool {
        guard motionAllowed, playedGeneration != generation else { return false }
        return scope?.isOpen() ?? true
    }

    var body: some View {
        content(isPending ? 0 : 1)
            .onAppear { isVisible = true; settle() }
            .onDisappear { isVisible = false }
            .onChange(of: generation) { if isVisible { settle() } }
    }

    private func settle() {
        guard playedGeneration != generation else { return }
        let target = generation
        if isPending, let delay = resolvedDelay() {
            withAnimation(animation.delay(delay)) { playedGeneration = target }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { playedGeneration = target }
        }
    }

    private func resolvedDelay() -> Double? {
        switch timing {
        case .delay(let delay): delay
        case .cascade(let index?): VoltaMotion.cascadeDelay(for: index)
        case .cascade(nil): scope.map { $0.claimCascadeSlot().flatMap(VoltaMotion.cascadeDelay(for:)) } ?? 0
        }
    }
}

/// Re-evaluates `content` every frame while `progress` animates.
private struct ProgressFrame<Content: View>: View, Animatable {
    nonisolated var progress: Double
    var content: (Double) -> Content
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    var body: some View { content(progress) }
}

// MARK: - Arrival effects

private struct RiseModifier: ViewModifier {
    var delay: Double
    func body(content: Content) -> some View {
        VoltaArrivalReader(animation: VoltaMotion.rise, timing: .delay(delay)) { p in
            content.opacity(p).offset(y: (1 - p) * 8)
        }
    }
}

private struct CascadeModifier: ViewModifier {
    var index: Int?
    func body(content: Content) -> some View {
        VoltaArrivalReader(animation: VoltaMotion.enter, timing: .cascade(index)) { p in
            content.opacity(p).offset(y: (1 - p) * 18).scaleEffect(0.98 + 0.02 * p)
        }
    }
}

private struct GrowModifier: ViewModifier {
    var index: Int
    func body(content: Content) -> some View {
        VoltaArrivalReader(animation: VoltaMotion.grow, timing: .delay(Double(max(index, 0)) * VoltaMotion.barStagger)) { p in
            content.scaleEffect(x: 1, y: max(p, 0.001), anchor: .bottom)
        }
    }
}

extension View {
    /// Rise and fade in when the screen arrives (stat strip columns: `delay: VoltaMotion.statDelay(i)`).
    func voltaArrival(delay: Double = 0) -> some View { modifier(RiseModifier(delay: delay)) }

    /// List card entrance: fade, 18pt rise, slight scale. Only the first `maxCascade`
    /// cards on a fresh screen animate; pass `index` or let the scope assign slots.
    func voltaCascade(index: Int? = nil) -> some View { modifier(CascadeModifier(index: index)) }

    /// Rhythm bar growing from the bottom, staggered left to right.
    func voltaGrow(index: Int) -> some View { modifier(GrowModifier(index: index)) }
}

// MARK: - Count up

/// Hero numeral that counts up from 0 when its screen arrives. Layout is reserved
/// at the final width (no jitter) and VoiceOver always reads the final value.
/// Later value changes roll like an odometer. Fonts and styles come from the caller.
struct CountUpNumber: View {
    var value: Double?
    var placeholder: String
    var delay: Double
    var alignment: Alignment
    var format: (Double) -> String

    init(_ value: Double?, placeholder: String = "—", delay: Double = 0, alignment: Alignment = .leading, format: @escaping (Double) -> String) {
        self.value = value
        self.placeholder = placeholder
        self.delay = delay
        self.alignment = alignment
        self.format = format
    }

    /// Counts up an already formatted number ("1,234", "26.7", "$4.10"), keeping its
    /// decimals, grouping, prefix and suffix. Non-numeric text ("4h 49m", "—") is shown as is.
    init(text: String, delay: Double = 0, alignment: Alignment = .leading) {
        let template = VoltaMotion.NumberTemplate(text)
        self.value = template?.value
        self.placeholder = text
        self.delay = delay
        self.alignment = alignment
        self.format = { v in
            guard let template, v != template.value else { return text }
            return template.string(for: v)
        }
    }

    var body: some View {
        if let value {
            let final = format(value)
            Text(final).hidden()
                .overlay(alignment: alignment) {
                    VoltaArrivalReader(animation: VoltaMotion.countUp, timing: .delay(delay)) { p in
                        CountUpText(progress: p, target: value, format: format)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(final)
        } else {
            Text(placeholder)
        }
    }
}

private struct CountUpText: View, Animatable {
    nonisolated var progress: Double
    var target: Double
    var format: (Double) -> String
    @VoltaMotionAllowed private var motionAllowed

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let settled = progress >= 1
        Text(format(VoltaMotion.countUpValue(target, progress: progress)))
            .contentTransition(settled && motionAllowed ? .numericText(value: target) : .identity)
            .animation(settled && motionAllowed ? VoltaMotion.roll : nil, value: target)
    }
}

private struct RollingNumberModifier: ViewModifier {
    var value: Double
    @VoltaMotionAllowed private var motionAllowed
    func body(content: Content) -> some View {
        content
            .contentTransition(motionAllowed ? .numericText(value: value) : .identity)
            .animation(motionAllowed ? VoltaMotion.roll : nil, value: value)
    }
}

extension View {
    /// Number text that rolls when `value` changes (scores, live SoC).
    func voltaRollingNumber(_ value: Double) -> some View { modifier(RollingNumberModifier(value: value)) }
}

// MARK: - Sweep in

/// Arc/ring/route drawn by progress 0→1. Dials sweep with a slight spring
/// overshoot (progress may briefly exceed 1); routes pass `VoltaMotion.routeDraw`.
/// Use `VoltaMotion.bloom(progress)` for the glow bloom while sweeping.
///
///     SweepIn { p in Circle().trim(from: 0, to: 0.75 * fraction * p) ... }
struct SweepIn<Content: View>: View {
    var animation: Animation
    var delay: Double
    var content: (Double) -> Content

    init(animation: Animation = VoltaMotion.sweep, delay: Double = 0, @ViewBuilder content: @escaping (Double) -> Content) {
        self.animation = animation
        self.delay = delay
        self.content = content
    }

    var body: some View {
        VoltaArrivalReader(animation: animation, timing: .delay(delay)) { p in
            ProgressFrame(progress: p, content: content)
        }
    }
}

// MARK: - Repeating clock

/// A timeline that ticks only while `isActive`, motion is allowed, the view is on
/// screen, its tab is active, and the scene is active. `elapsed` is nil when paused
/// (draw the static state) and otherwise counts from when it started running.
struct MotionTimeline<Content: View>: View {
    var isActive: Bool
    var minimumInterval: Double?
    var content: (_ elapsed: TimeInterval?) -> Content
    @VoltaMotionAllowed private var motionAllowed
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isActiveTab) private var isActiveTab
    @State private var hasAppeared = false
    @State private var isInViewport = true
    @State private var startedAt: Date?

    init(isActive: Bool, minimumInterval: Double? = nil, @ViewBuilder content: @escaping (_ elapsed: TimeInterval?) -> Content) {
        self.isActive = isActive
        self.minimumInterval = minimumInterval
        self.content = content
    }

    private var isRunning: Bool {
        VoltaMotion.shouldRun(isActive: isActive, motionAllowed: motionAllowed, isVisible: hasAppeared && isInViewport, isActiveTab: isActiveTab, scenePhase: scenePhase)
    }

    var body: some View {
        let running = isRunning
        TimelineView(.animation(minimumInterval: minimumInterval, paused: !running)) { context in
            content(running ? max(0, context.date.timeIntervalSince(startedAt ?? context.date)) : nil)
        }
        .onAppear { hasAppeared = true }
        .onDisappear { hasAppeared = false }
        // Eager stacks keep views "appeared" after they scroll away; check the viewport too.
        .onGeometryChange(for: Bool.self) { proxy in
            VoltaMotion.isInViewport(size: proxy.size, scrollBounds: proxy.bounds(of: .scrollView))
        } action: { isInViewport = $0 }
        .onChange(of: running, initial: true) { _, running in startedAt = running ? .now : nil }
    }
}

// MARK: - Live pulse

/// Two rings expanding from a status dot, 1s apart on a 2s period. Only while live.
struct LivePulseRings: View {
    var color: Color
    var isLive: Bool

    var body: some View {
        MotionTimeline(isActive: isLive, minimumInterval: 1.0 / 30) { elapsed in
            if let elapsed {
                ZStack {
                    ring(VoltaMotion.pulseRing(time: elapsed, offset: 0))
                    ring(VoltaMotion.pulseRing(time: elapsed, offset: VoltaMotion.pulseStagger))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func ring(_ state: (scale: Double, opacity: Double)) -> some View {
        Circle().fill(color).scaleEffect(state.scale).opacity(state.opacity)
    }
}

/// Status dot with an optional live ripple.
struct LivePulse: View {
    var color: Color
    var isLive: Bool
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .voltaLivePulse(color: color, isLive: isLive)
    }
}

extension View {
    /// Ripple behind an existing dot while the car is driving or charging. Static otherwise.
    func voltaLivePulse(color: Color, isLive: Bool) -> some View {
        background { LivePulseRings(color: color, isLive: isLive) }
    }
}

// MARK: - Comet

/// Grants the comet to one list row at a time.
@MainActor
final class CometLease {
    static let shared = CometLease()
    private var owner: UUID?

    func claim(_ id: UUID) -> Bool {
        if owner == nil || owner == id { owner = id; return true }
        return false
    }

    func release(_ id: UUID) {
        if owner == id { owner = nil }
    }
}

/// A soft point of light gliding start→end along `path` every few seconds, after
/// the route draws on. Draw in the same coordinate space as the path.
struct CometPath: View {
    var path: Path
    var isActive: Bool
    var color: Color = Color(hex: 0x7DD3FC)
    @State private var leaseID = UUID()
    @State private var holdsLease = false

    var body: some View {
        MotionTimeline(isActive: isActive && holdsLease) { elapsed in
            if let elapsed, let state = VoltaMotion.comet(elapsed: elapsed), state.opacity > 0,
               let point = path.trimmedPath(from: 0, to: max(state.fraction, 0.0001)).currentPoint {
                ZStack {
                    Circle().fill(color).frame(width: 12, height: 12).blur(radius: 3).opacity(0.9)
                    Circle().fill(.white).frame(width: 4, height: 4)
                }
                .opacity(state.opacity)
                .position(point)
            }
        }
        .onAppear { holdsLease = isActive && CometLease.shared.claim(leaseID) }
        .onChange(of: isActive) { _, active in
            if active { holdsLease = CometLease.shared.claim(leaseID) } else { CometLease.shared.release(leaseID); holdsLease = false }
        }
        .onDisappear { CometLease.shared.release(leaseID); holdsLease = false }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Breathing glow

private struct BreathingGlowModifier: ViewModifier {
    var color: Color
    var radius: CGFloat
    var isActive: Bool

    func body(content: Content) -> some View {
        MotionTimeline(isActive: isActive, minimumInterval: 1.0 / 30) { elapsed in
            let amount = elapsed.map(VoltaMotion.breath) ?? 0
            content
                .shadow(color: color.opacity(0.5 * amount), radius: radius * (0.5 + amount))
                .scaleEffect(x: 1, y: 1 + 0.04 * amount, anchor: .bottom)
        }
    }
}

extension View {
    /// Slow breathing glow (today's bar). Static when inactive or motion is off.
    func voltaBreathingGlow(color: Color, radius: CGFloat = 8, isActive: Bool = true) -> some View {
        modifier(BreathingGlowModifier(color: color, radius: radius, isActive: isActive))
    }
}

// MARK: - Energy flow

/// Horizontal centerline, for flow along linear gauges.
struct FlowLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// Small light pulses travelling along `shape` toward the charge level, clipped to
/// the filled portion (`fraction` of the path). Only while charging.
struct EnergyFlow<S: Shape>: View {
    var shape: S
    var fraction: Double
    var lineWidth: CGFloat
    var spacing: CGFloat
    var isActive: Bool

    init(shape: S, fraction: Double, lineWidth: CGFloat = 2, spacing: CGFloat = 34, isActive: Bool) {
        self.shape = shape
        self.fraction = fraction
        self.lineWidth = lineWidth
        self.spacing = spacing
        self.isActive = isActive
    }

    var body: some View {
        MotionTimeline(isActive: isActive && fraction > 0) { elapsed in
            if let elapsed {
                shape.trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                                                    dash: [2, max(spacing - 2, 1)],
                                                                    dashPhase: VoltaMotion.flowPhase(elapsed, spacing: spacing)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
