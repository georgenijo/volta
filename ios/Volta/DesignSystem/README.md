# Volta DesignSystem

Owned by Screens A. Other screens read and use it; ask Screens A for changes
(APIs only change additively). Every component has a `#Preview`.

## Tokens (`Theme.swift`)

| Token | Value / use |
|---|---|
| `Color.voltaBackground` | `#0E0F11` app background. Use `.voltaScreenBackground()` on screens. |
| `Color.voltaCard` | `#17191C` card surface |
| `Color.voltaRaised` | `#23262B` pill buttons, steppers, selected segment |
| `Color.voltaHairline` | white @ 8%, borders and dividers |
| `Color.voltaTextPrimary / Secondary / Tertiary` | white / `#8A8F98` / `#5C6068` |
| `Color.voltaBlue / Green / Amber / Red` | `#3B82F6` selection, range / `#22C55E` online, on / `#F59E0B` warm, warnings / `#EF4444` alerts |
| `Color(hex: 0xRRGGBB)` | literal helper |
| `VoltaSpacing.xxs…xxl` | 2, 4, 8, 12, 16, 24, 32 |
| `VoltaSpacing.screen` | 20, horizontal screen inset |
| `VoltaSpacing.tabBarClearance` | 110, bottom content inset so the floating tab bar doesn't cover content |
| `VoltaRadius.card / control / wideButton` | 20 / 12 / 14 |
| `Font.voltaNumeral(size)` | heavy SF Pro numerals (prefer `BigNumber`) |
| `Font.voltaLabel`, `.voltaCardTitle`, `.voltaRowTitle`, `.voltaRowSubtitle`, `.voltaScreenTitle`, `.voltaUnit` | text styles (all Dynamic Type aware) |
| `.voltaLabelStyle(color:)` | small-caps label treatment: uppercase, 11pt semibold, +1.5 tracking, gray |

All tokens also work as `ShapeStyle` shorthands: `.foregroundStyle(.voltaTextSecondary)`.

## Components

| Component | Example |
|---|---|
| `Card` | `Card { … }`, `Card(padding: 0, tint: .voltaAmber) { … }`; or `.voltaCardBackground(tint:)` on any view |
| `SectionLabel` | `SectionLabel("Last 48h")`, `SectionLabel("Access", trailing: "5 controls", rule: true)`, `SectionLabel("Activity") { SegmentedRangePicker(…) }` |
| `HairlineDivider` | `HairlineDivider(leadingInset: 52)` (52 aligns with ListRow text) |
| `StatusDot` | `StatusDot(color: .voltaGreen)` |
| `EmptyState` | `EmptyState(systemImage: "bolt.slash", title: "No charges in 30 days", message: "Try a different range…")` |
| `InlineBanner` | `InlineBanner(systemImage: "lock.slash", message: "…", tint: .voltaAmber, onDismiss: { … })` |
| `BigNumber` | `BigNumber("78", unit: "%", size: 84)`; `weight:` and `color:` optional; scales with Dynamic Type |
| `GradientGauge` | `GradientGauge(value: 0.68)`; `value: nil` draws an empty track; `colors: GradientGauge.daylight`, `knob: .ring / .filled(color) / .none`, `secondaryValue:` |
| `MetricCard` | `MetricCard(systemImage:, title:, value:, unit:, badge: .init(text: "WARM", color: .voltaAmber), gauge: GradientGauge(value: 0.6), tint: .voltaAmber) { optional accessory }` |
| `StatColumn` | `StatColumn(value: "12", caption: "MI")` — centered numeral + caption for summary rows |
| `ListRow` | `ListRow(systemImage: "bolt", title: "Home", subtitle: "Today · 42 kWh", showsChevron: true) { Text("$4.10") }` — plain view; wrap in `NavigationLink`/`Button` (use `.buttonStyle(.plain)`) |
| `ToggleRow` | `ToggleRow(systemImage: "lock.fill", title: "Doors", subtitle: "Lock & unlock", status: "Locked", isOn: $locked, isEnabled: true)` |
| `PillButton` | `PillButton("Open") { … }`, `PillButton("Close", size: .wide) { … }`, `style: .accent`, `isBusy:` |
| `VoltaPressStyle` | `.buttonStyle(VoltaPressStyle())` dim+scale press feedback for custom buttons |
| `SegmentedRangePicker` | `SegmentedRangePicker(selection: $range)` for `SummaryRange`; generic: `SegmentedRangePicker(selection: $x, options: [...]) { label }` |
| `GlassCircleButton` | `GlassCircleButton(systemImage: "bell.fill", badge: true, accessibilityLabel: "Notifications") { … }` (Liquid Glass, 50pt default) |
| `GlassPill` | `GlassPill { Button { } label: { Image(systemName: "magnifyingglass") }; … }` capsule glass group for header buttons |
| `VoltaHeader` | `VoltaHeader("Charging") { leading } trailing: { trailing }` — centered title with glass controls, like the history screens |

## Conventions

- Screens use `.voltaScreenBackground()` and `.preferredColorScheme(.dark)` is
  set app-wide by `MainShell`.
- History/More screens own their `NavigationStack` and hide the system nav
  bar; `MainShell` embeds them bare and floats the tab bar over them. Add
  `.contentMargins(.bottom, VoltaSpacing.tabBarClearance, for: .scrollContent)`
  (or equivalent) to scroll views.
- Section label → content spacing: 12–16pt. Between sections: 28–32pt.
- Show "—" for nil values (`null` means "not recorded", never zero).
