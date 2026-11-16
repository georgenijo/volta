import SwiftUI

/// One tile of the Dashboard dock: the state first ("Locked"), then what a
/// tap does ("Unlock").
struct DockTile: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case lock, climate, sentry, windows, frunk, trunk, lights, controls }
    enum Tone: Equatable {
        case neutral
        /// Unlocked: amber.
        case attention
        /// Sentry armed: a red icon; the text stays neutral.
        case armed
        /// State not reported: quieter text.
        case unknown
    }
    enum Tap: Equatable {
        case send(VehicleCommand)
        case openControls
    }

    var kind: Kind
    var symbol: String
    var title: String
    var action: String
    var tone: Tone
    var tap: Tap
    var accessibilityLabel: String
    /// A switched-on state (climate running): the plate is filled.
    var isOn = false

    var id: Kind { kind }

    /// The eight tiles for the observed state. A tile whose command the
    /// server cannot run (controls not enabled, or the capability missing),
    /// and a lock, climate or Sentry tile whose state is unknown, opens
    /// Controls instead of sending.
    static func tiles(locked: Bool?, climateOn: Bool?, sentry: Bool?,
                      supports: (VehicleCommand) -> Bool) -> [DockTile] {
        func tile(_ kind: Kind, _ symbol: String, _ title: String, _ action: String, _ tone: Tone,
                  _ command: VehicleCommand?, label: String) -> DockTile {
            guard let command else {
                // Unknown state: say so, and let Controls show the choices.
                return DockTile(kind: kind, symbol: symbol, title: title, action: action, tone: tone,
                                tap: .openControls, accessibilityLabel: label)
            }
            guard supports(command) else {
                return DockTile(kind: kind, symbol: symbol, title: title, action: "Open Controls",
                                tone: tone, tap: .openControls,
                                accessibilityLabel: "\(title). Opens Controls")
            }
            return DockTile(kind: kind, symbol: symbol, title: title, action: action, tone: tone,
                            tap: .send(command), accessibilityLabel: label)
        }

        let lock: DockTile = switch locked {
        case true?: tile(.lock, "lock.fill", "Locked", "Unlock", .neutral, .unlock, label: "Doors locked. Unlock")
        case false?: tile(.lock, "lock.open.fill", "Unlocked", "Lock", .attention, .lock, label: "Doors unlocked. Lock")
        case nil: tile(.lock, "lock.fill", "Doors", "Unknown", .unknown, nil, label: "Lock state unknown. Opens Controls")
        }
        let climate: DockTile = { switch climateOn {
        case true?:
            var on = tile(.climate, "fan.fill", "Climate on", "Turn off", .neutral, .climateOff, label: "Climate on. Turn off")
            on.isOn = true
            return on
        case false?: return tile(.climate, "fan", "Climate off", "Turn on", .neutral, .climateOn, label: "Climate off. Turn on")
        case nil: return tile(.climate, "fan", "Climate", "Unknown", .unknown, nil, label: "Climate state unknown. Opens Controls")
        } }()
        let sentryTile: DockTile = switch sentry {
        case true?: tile(.sentry, "shield.lefthalf.filled", "Sentry on", "Turn off", .armed, .sentryOff, label: "Sentry on. Turn off")
        case false?: tile(.sentry, "shield", "Sentry off", "Turn on", .neutral, .sentryOn, label: "Sentry off. Turn on")
        case nil: tile(.sentry, "shield", "Sentry", "Unknown", .unknown, nil, label: "Sentry state unknown. Opens Controls")
        }
        return [
            lock, climate, sentryTile,
            tile(.windows, "window.vertical.open", "Windows", "Vent", .neutral, .windowControl(command: .vent), label: "Vent windows"),
            tile(.frunk, "car.side.front.open", "Frunk", "Open", .neutral, .actuateTrunk(whichTrunk: .front), label: "Open frunk"),
            tile(.trunk, "car.side.rear.open", "Trunk", "Open", .neutral, .actuateTrunk(whichTrunk: .rear), label: "Open trunk"),
            tile(.lights, "headlight.high.beam", "Lights", "Flash", .neutral, .flash, label: "Flash lights"),
            DockTile(kind: .controls, symbol: "slider.horizontal.3", title: "Controls", action: "Show all", tone: .neutral,
                     tap: .openControls, accessibilityLabel: "Controls. Show all"),
        ]
    }
}

/// The Dashboard's 4×2 grid of quick controls (2 columns at accessibility sizes).
struct DashboardDock: View {
    var tiles: [DockTile]
    /// Tiles whose command is sending now (shows progress).
    var sending: (DockTile) -> Bool
    /// Tiles that cannot start a command right now (another is in flight).
    var blocked: (DockTile) -> Bool
    var tap: (DockTile) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: VoltaSpacing.sm),
                            count: typeSize.isAccessibilitySize ? 2 : 4)
        LazyVGrid(columns: columns, spacing: VoltaSpacing.md) {
            ForEach(tiles) { tile in
                DockTileButton(tile: tile, isSending: sending(tile)) { tap(tile) }
                    .disabled(blocked(tile))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick controls")
    }
}

/// A round plate with the control's symbol, then its state and what a tap
/// does. No box: the plate is the button, as in Control Center.
private struct DockTileButton: View {
    var tile: DockTile
    var isSending: Bool
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var plate: CGFloat = 52

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(plateFill)
                    // Each tile names its own symbol variant: small glyphs
                    // are filled, the wide car outlines are drawn smaller.
                    Image(systemName: tile.symbol)
                        .font(.system(wideGlyph ? .body : .title3, weight: .medium))
                        .foregroundStyle(iconColor)
                        .opacity(isSending ? 0 : 1)
                    if isSending { ProgressView().controlSize(.small).tint(tile.isOn ? .black : .white) }
                }
                .frame(width: plate, height: plate)
                VStack(spacing: 1) {
                    Text(tile.title)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(titleColor)
                    Text(tile.action)
                        .font(.caption)
                        .foregroundStyle(Color.voltaTextSecondary)
                }
                // Two columns at accessibility sizes leave room to wrap instead.
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.75)
            }
            .padding(.vertical, VoltaSpacing.xs)
            .frame(maxWidth: .infinity, minHeight: 62)
            .contentShape(.rect)
        }
        .buttonStyle(VoltaPressStyle())
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(tile.accessibilityLabel)
        .accessibilityIdentifier(tile.kind == .controls ? "button.controls" : "dock.\(tile.kind.rawValue)")
    }

    private var wideGlyph: Bool { tile.kind == .frunk || tile.kind == .trunk }

    private var plateFill: Color {
        if tile.isOn { return .voltaTextPrimary }
        switch tile.tone {
        case .attention: return .voltaAmber.opacity(0.2)
        case .armed: return .voltaRed.opacity(0.2)
        case .unknown: return .white.opacity(0.05)
        case .neutral: return .white.opacity(0.08)
        }
    }

    private var iconColor: Color {
        if tile.isOn { return .black }
        switch tile.tone {
        case .attention: return .voltaAmber
        case .armed: return .voltaRed
        case .unknown: return .voltaTextSecondary
        case .neutral: return .voltaTextPrimary
        }
    }

    private var titleColor: Color {
        switch tile.tone {
        case .attention: .voltaAmber
        case .unknown: .voltaTextSecondary
        case .neutral, .armed: .voltaTextPrimary
        }
    }
}
