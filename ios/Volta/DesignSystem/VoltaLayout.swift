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

/// Where two panes meet, along the split axis, in the container's own
/// coordinates: the first pane ends at `firstEnd`, the second starts at
/// `secondStart`. The space between them is the fold, which nothing may cross.
struct PaneSplit: Equatable {
    var firstEnd: CGFloat
    var secondStart: CGFloat

    /// Narrowest pane worth splitting for; a hinge closer to an edge than
    /// this is not inside this container in any useful sense.
    nonisolated static let minimumPane: CGFloat = 220

    /// The split for a container `length` long along the axis.
    ///
    /// - Parameters:
    ///   - division: the system's division region (the hinge) along the axis,
    ///     in the container's coordinates, and whether it is active. Active
    ///     (partly folded) it includes the margins interactive content must
    ///     keep; inactive (open flat) only its middle matters.
    ///   - windowOffset: how far the container starts from the window's edge
    ///     along the axis, bars included. With no division region the window's
    ///     middle is the fold, but only a container that starts at the window's
    ///     edge can know where that middle is.
    ///   - insets: the bars at the container's two ends along the axis.
    nonisolated static func resolve(length: CGFloat, division: (range: ClosedRange<CGFloat>, isActive: Bool)?,
                        windowOffset: CGFloat, insets: (leading: CGFloat, trailing: CGFloat)) -> PaneSplit? {
        guard length > minimumPane * 2 else { return nil }
        if let division {
            let split = division.isActive
                ? PaneSplit(firstEnd: division.range.lowerBound, secondStart: division.range.upperBound)
                : PaneSplit(firstEnd: (division.range.lowerBound + division.range.upperBound) / 2,
                            secondStart: (division.range.lowerBound + division.range.upperBound) / 2)
            if split.firstEnd >= minimumPane, length - split.secondStart >= minimumPane { return split }
        }
        guard abs(windowOffset) < 1 else { return nil }
        let middle = (insets.leading + length + insets.trailing) / 2 - insets.leading
        guard middle >= minimumPane, length - middle >= minimumPane else { return nil }
        return PaneSplit(firstEnd: middle, secondStart: middle)
    }
}

/// Measures a container for `PaneSplit`: the system's division region where
/// the SDK has it, else the window's middle (bars included).
private struct PaneSplitReader: ViewModifier {
    var axis: Axis
    @Binding var split: PaneSplit?

    func body(content: Content) -> some View {
        content.onGeometryChange(for: PaneSplit?.self) { proxy in
            let frame = proxy.frame(in: .global)
            let insets = proxy.safeAreaInsets
            let horizontal = axis == .horizontal
            return PaneSplit.resolve(
                length: horizontal ? proxy.size.width : proxy.size.height,
                division: Self.division(proxy, axis: axis),
                windowOffset: horizontal ? frame.minX - insets.leading : frame.minY - insets.top,
                insets: horizontal ? (insets.leading, insets.trailing) : (insets.top, insets.bottom))
        } action: { split = $0 }
    }

    nonisolated private static func division(_ proxy: GeometryProxy, axis: Axis) -> (range: ClosedRange<CGFloat>, isActive: Bool)? {
        // `ReservedRegion` is in the iOS 27.1 SDK; see `VoltaPanes`.
        #if compiler(>=6.4.2)
        if #available(iOS 27.1, *) {
            let size = proxy.size
            // A division across the split axis (a vertical hinge for side by side).
            let regions = proxy.reservedRegions(kind: .division, options: .includeInactive).filter { region in
                axis == .horizontal
                    ? region.frame.height >= size.height * 0.5 && region.frame.width < size.width * 0.5
                    : region.frame.width >= size.width * 0.5 && region.frame.height < size.height * 0.5
            }
            #if DEBUG
            // Layout aid: `-logPanes YES` logs what the system reports.
            if UserDefaults.standard.bool(forKey: "logPanes") {
                let division = proxy.reservedRegions(kind: .division, options: .includeInactive)
                    .map { "\($0.frame) active=\($0.isActive) margins=\($0.margins)" }
                let occlusion = proxy.reservedRegions(kind: .occlusion, options: .includeInactive)
                    .map { "\($0.frame) active=\($0.isActive)" }
                NSLog("VoltaPanes %@ size=%@ global=%@ insets=%@ division=%@ occlusion=%@", "\(axis)", "\(size)",
                      "\(proxy.frame(in: .global))", "\(proxy.safeAreaInsets)", "\(division)", "\(occlusion)")
            }
            #endif
            guard let region = regions.first(where: \.isActive) ?? regions.first else { return nil }
            let range = axis == .horizontal ? region.frame.minX...region.frame.maxX : region.frame.minY...region.frame.maxY
            return (range, region.isActive)
        }
        #endif
        return nil
    }
}

extension View {
    /// Publishes where this container would split into two panes across the
    /// fold, or nil when it does not span one.
    func readsPaneSplit(_ axis: Axis = .horizontal, into split: Binding<PaneSplit?>) -> some View {
        modifier(PaneSplitReader(axis: axis, split: split))
    }
}

/// Two panes that share a regular-width window: side by side when the window
/// is wider than it is tall, or one above the other along `axis: .vertical`.
/// On iPhone Duo the panes meet on the hinge: open flat each takes its half of
/// the window (bars included), and partly folded each gives up the fold's
/// margin and nothing else moves. A container that does not span the fold
/// (for example a detail column) splits as the system arranges it.
/// Navigation containers go around this view, not inside it.
struct VoltaPanes<Primary: View, Secondary: View>: View {
    var axis: Axis
    var primary: Primary
    var secondary: Secondary
    @State private var split: PaneSplit?

    init(axis: Axis = .horizontal, @ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary) {
        self.axis = axis
        self.primary = primary()
        self.secondary = secondary()
    }

    var body: some View {
        Group {
            if let split {
                hingeSplit(split)
            } else {
                systemSplit
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .readsPaneSplit(axis, into: $split)
    }

    private func hingeSplit(_ split: PaneSplit) -> some View {
        GeometryReader { proxy in
            let length = axis == .horizontal ? proxy.size.width : proxy.size.height
            let second = max(0, length - split.secondStart)
            if axis == .horizontal {
                HStack(spacing: 0) {
                    primary.frame(width: split.firstEnd)
                    Color.clear.frame(width: max(0, split.secondStart - split.firstEnd))
                        .accessibilityHidden(true)
                    secondary.frame(width: second)
                }
            } else {
                VStack(spacing: 0) {
                    primary.frame(height: split.firstEnd)
                    Color.clear.frame(height: max(0, split.secondStart - split.firstEnd))
                        .accessibilityHidden(true)
                    secondary.frame(height: second)
                }
            }
        }
    }

    @ViewBuilder
    private var systemSplit: some View {
        // `ArrangementView` is in the iOS 27.1 SDK. Xcode 27.2 (Swift 6.4.2)
        // is known to have it; older toolchains, such as CI's, build the
        // plain layout only.
        #if compiler(>=6.4.2)
        if #available(iOS 27.1, *) {
            ArrangementView { primary } secondary: { secondary }
                .arrangementViewStyle(.split.axes(axis == .horizontal ? .horizontal : .vertical))
        } else {
            evenSplit
        }
        #else
        evenSplit
        #endif
    }

    @ViewBuilder
    private var evenSplit: some View {
        if axis == .horizontal {
            HStack(spacing: 0) {
                primary.frame(maxWidth: .infinity)
                secondary.frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                primary.frame(maxHeight: .infinity)
                secondary.frame(maxHeight: .infinity)
            }
        }
    }
}
