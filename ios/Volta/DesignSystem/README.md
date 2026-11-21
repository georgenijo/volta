# Volta DesignSystem

Owned by Screens A. Other screens read and use it; ask Screens A for changes
(APIs only change additively). Every component has a `#Preview`.

## Tokens (`Theme.swift`)

| Token | Value / use |
|---|---|
| `Color(light:dark:)` | the one way to make a colour that follows the system appearance; every token below uses it |
| `Color.voltaBackground` | page: `#171717` dark, `#F2F2F7` light. Use `.voltaScreenBackground()` on screens. |
| `Color.voltaCard` | card surface: `#202020` dark, white light (with `voltaCardShadow`) |
| `Color.voltaRaised` | pill buttons, steppers, selected segment: `#2C2C2C` / `#E5E5EA` |
| `Color.voltaHairline`, `.voltaControlFill`, `.voltaTrack` | borders and dividers; borderless button fill; gauge and bar tracks |
| `Color.voltaInk` / `.voltaInkInverse` | white / near-black ink for washes at an opacity; its opposite for glyphs on an ink plate |
| `Color.voltaMapWash`, `.voltaMapBackdrop` | map dim and text halos; map placeholder |
| `Color.voltaTextPrimary / Secondary / Tertiary` | all meet 4.5:1 on the background and on cards in both modes |
| `Color.voltaOnAccent`, `.voltaOnState` | white text on saturated fills; a glyph on a state-coloured pin |
| `Color.voltaBlue / Green / Amber / Red / Purple / Teal` | selection and range / online, on / warm, warnings / alerts / regen / climate |
| `Color.voltaBlueFill` | fill behind white button labels (5.2:1 dark, 6.7:1 light) |
| `VoltaGradient.charge / .range` | range bar fills |
| `Color(hex: 0xRRGGBB)` | literal helper, for use inside `Color(light:dark:)` |
| `VoltaSpacing.xxs…xxl` | 2, 4, 8, 12, 16, 24, 32 |
| `VoltaSpacing.screen` | 20, horizontal screen inset |
| `VoltaSpacing.tabBarClearance` | 24, breathing room below the last item of a scrolling screen (the system tab bar already insets scroll content) |
| `VoltaRadius.card / control / wideButton` | 20 / 12 / 14 |
| `Font.voltaNumeral(size)` | heavy SF Pro numerals (prefer `BigNumber`) |
| `Font.voltaLabel`, `.voltaCardTitle`, `.voltaRowTitle`, `.voltaRowSubtitle`, `.voltaScreenTitle`, `.voltaUnit` | text styles (all Dynamic Type aware) |
| `.voltaLabelStyle(color:)` | label treatment: footnote semibold, gray, sentence case as written |

All tokens also work as `ShapeStyle` shorthands: `.foregroundStyle(.voltaTextSecondary)`.

## Components

| Component | Example |
|---|---|
| `Card` | `Card { … }`, `Card(padding: 0, tint: .voltaAmber) { … }`; or `.voltaCardBackground(tint:)` on any view |
| `SectionLabel` | `SectionLabel("Last 48h")`, `SectionLabel("Access", trailing: "5 controls", rule: true)`, `SectionLabel("Activity") { SegmentedRangePicker(…) }` |
| `HairlineDivider` | `HairlineDivider(leadingInset: 52)` (52 aligns with ListRow text) |
| `StatusDot` | `StatusDot(color: .voltaGreen)` |
| `EmptyState` | `EmptyState(systemImage: "bolt.slash", title: "No charges in 30 days", message: "…", action: .init("Show all time") { … })` — icon bounces and the state focuses in |
| `ErrorState` | `ErrorState(title: "Couldn't load drives", message: …) { await reload() }` — amber icon and Try again |
| `.voltaSkeleton(_:)` | `RowView(.sample).voltaSkeleton(isLoading)` — the real layout as shimmering placeholders |
| `.voltaFocusIn(_:)` | `row.voltaFocusIn(index)` — blur-and-scale entrance, staggered by index |
| `RollingNumber` | `RollingNumber(value: 231) { VoltaFormat.number($0, digits: 0) }` — rolls up from zero, then between values |
| `.voltaRolling(_:)` | `Text(label).voltaRolling(value)` — digits roll when a displayed value changes |
| `.voltaFeedback(_:trigger:)` | `.voltaFeedback(.commandConfirmed, trigger: n)`; or `.voltaFeedback(trigger: x) { old, new in … }` |
| `InlineBanner` | `InlineBanner(systemImage: "lock.slash", message: "…", tint: .voltaAmber, onDismiss: { … })` |
| `BigNumber` | `BigNumber("78", unit: "%", size: 84)`; `weight:` and `color:` optional; scales with Dynamic Type |
| `TemperatureScale` | `TemperatureScale(markers: [.init(id: "C", fraction: 0.4)], lowLabel: "23°F", highLabel: "113°F")` — one cold-to-hot track, a lettered tag per reading, labelled ends |
| `LevelBar` | `LevelBar(value: 0.3, color: .voltaGreen, lowLabel: "160 efficient", highLabel: "400 heavy")` — capacity fill with labelled ends; `value: nil` draws an empty track |
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

- Screens use `.voltaScreenBackground()`. Volta follows the system light and
  dark appearance; never force a scheme. Colours come from tokens, or from
  `Color(light:dark:)` for a colour no token covers (see docs/APPEARANCE.md).
- `MainShell` is a system `TabView`; screens own their `NavigationStack`. The
  system places the tab bar and toolbars: at the bottom and top on most
  iPhones, and in a strip on the side on iPhone Duo's outer display and its
  inner display opened flat. Do not draw bars or pin controls to an edge.
- Screen controls are system toolbar items, each a `Label` with a title and a
  symbol, tinted `Color.voltaTextPrimary`. Use the system back button.
- A title in the navigation bar keeps a horizontal bar alive. Put it in the
  bar only when `@Environment(\.barsOnSide)` is false, and draw it in the
  content otherwise (see `DashboardView`).
- Branch on size classes and the window's shape, never on a device or screen
  size. At regular width use the room: `VoltaPanes` for two parts side by
  side (the system keeps both clear of the fold), a split view for list and
  detail, and `voltaReadableWidth()` to cap a single column.
- Backdrops that run to the screen edge ignore the top and horizontal safe
  areas, so they continue under a side bar.
- Scroll views add `VoltaSpacing.tabBarClearance` below their last item.
- Section label → content spacing: 12–16pt. Between sections: 28–32pt.
- Show "—" for nil values (`null` means "not recorded", never zero).

## Design rules

These hold on every screen. A change that breaks one needs a reason written
next to it.

**Colour means one thing.**
- Green: energy going in (charging, the charging battery) and efficient driving.
- Blue: the battery at rest, online or live, selection and links.
- Teal: climate running.
- Amber: a warning or attention (unlocked, stale data, warm, heavy use).
- Red: a problem or Sentry. Never decoration and never a data series.
- The blue-to-red temperature gradient appears only on temperature scales.
- Everything else is ink and greys. Cards carry no tinted glows; a card's
  border may take its state colour (the charging card).

**Gauges measure.** A bar or scale labels both ends and fills from the start
(`LevelBar`) or marks values on one shared scale (`TemperatureScale`). No
slider thumbs on things that can't be dragged, and no gauge whose position
means something other than its reading.

**Type.** Sentence case everywhere; no tracked all-caps labels. Spell words
out ("30-day efficiency", not "30D EFF"). Hierarchy comes from size and
weight: one large reading per card, labels in `voltaLabel`.

**No glow.** No shadows or halos on numbers, bars or knobs. Depth comes from
the card fill (dark) or a soft card shadow (light).

**Motion** (`VoltaMotion.swift`) is part of the character: keep it, and use
the shared springs.
- Numbers roll: `RollingNumber` for a headline figure as it appears,
  `.voltaRolling` (or `BigNumber`, which does it) for values that update.
- Content focuses in: `.voltaFocusIn(index)` on cards and the first screenful
  of rows.
- Readings settle: gauges glide to their value with `VoltaMotion.settle`.
- Small rewards pop: `VoltaMotion.pop` and SF Symbol effects (a fan that
  turns while climate runs, a bounce on an empty state).
- Only live processes loop (charging flow, a spinning fan, skeleton sweep).
- Everything has a Reduce Motion answer: no movement, a fade at most.

**Haptics** (`VoltaFeedback.swift`): commands sent, confirmed and failed;
stepper steps and limits; selection changes; a refresh that brought data.
Nothing else buzzes.

**States.** A screen is never blank. Loading shows the real layout as a
skeleton (`.voltaSkeleton`); nothing to show is an `EmptyState` that says why
and offers the next step; a failure is an `ErrorState` with Try again.
Unknown values are an em dash, never zero.
