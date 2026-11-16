# Appearance

Volta follows the iOS appearance setting. It is light when the system is light
and dark when it is dark, and it switches live, including on the automatic
sunset schedule. There is no in-app setting. Dark mode is the original "lit
instrument panel" look, value for value. Light mode is its native light
counterpart: the iOS grouped grey page, white cards lifted by a soft shadow,
and deeper accent colours that read on white.

## One mechanism

Every colour that depends on the appearance is built with
`Color(light:dark:)` (`ios/Volta/DesignSystem/Theme.swift`). It wraps a
dynamic `UIColor`, so it resolves wherever SwiftUI draws, including `Canvas`,
Charts and `ImageRenderer`, and it switches when the trait changes. The widget
extension has the same initialiser in `ios/VoltaWidgets/Extension/Theme.swift`.

- Feature code uses tokens (`Color.voltaTextPrimary`, `.voltaInk.opacity(0.06)`, and so on).
  A colour no token covers is a local `Color(light:dark:)` with a comment that gives its purpose.
- Nothing forces a scheme. `preferredColorScheme`, `.environment(\.colorScheme, …)` and
  `overrideUserInterfaceStyle` are banned outside the allowlist below.
- A colour that is the same in both modes by design carries an `// appearance: fixed (reason)`
  comment on its line. An alpha-only mask carries `// appearance: mask (alpha only)`.
- `VoltaTests/AppearanceGuardTests` fails the build's tests when a forced scheme or a
  bare colour literal (`Color(hex:)`, `Color(red:)`, `Color(hue:)`, `UIColor(…)`, or a
  named colour such as `.white`, `.black` or `.red`) appears outside the theme files.
  Both are matched across lines and whatever the spacing. No comment exempts a forced
  scheme; the only one
  allowed is the trip share card's. A colour literal passes inside `Color(light:dark:)`
  or on a line marked with one of the comments above.
  `VoltaTests/AppearanceTests` pins every token's light and dark value and checks the
  text and graphics contrast below.

## Palette

The usual backgrounds are the page (`voltaBackground`) and the card (`voltaCard`).
Contrast is the WCAG 2 ratio. Translucent tokens are composited over the background first.
The bar is 4.5:1 for text and 3:1 for meaningful graphics.

| Token | Use | Dark | Light | Contrast dark | Contrast light |
|---|---|---|---|---|---|
| `voltaBackground` | page | `#171717` | `#F2F2F7` | — | — |
| `voltaCard` | card surface (light: plus a soft shadow) | `#202020` | `#FFFFFF` | 1.10:1 on page | 1.12:1 on page |
| `voltaRaised` | selected segment, steppers | `#2C2C2C` | `#E5E5EA` | 1.2:1 card, 1.3:1 page | 1.3:1 card, 1.1:1 page |
| `voltaHairline` | borders, dividers | `#FFFFFF` @ 8% | `#000000` @ 8% | 1.3:1 card, 1.2:1 page | 1.2:1 card, 1.2:1 page |
| `voltaControlFill` | borderless button fill | `#FFFFFF` @ 10% | `#767680` @ 12% | 1.3:1 card, 1.3:1 page | 1.1:1 card, 1.1:1 page |
| `voltaTrack` | gauge and bar tracks | `#FFFFFF` @ 10% | `#787880` @ 20% | 1.3:1 card, 1.3:1 page | 1.3:1 card, 1.2:1 page |
| `voltaInk` | washes, rules, grid lines (at an opacity) | `#FFFFFF` | `#111111` | 16.3:1 card, 17.9:1 page | 18.9:1 card, 16.9:1 page |
| `voltaInkInverse` | glyph on an ink plate (dock "on") | `#000000` | `#FFFFFF` | — | — |
| `voltaMapWash` | map dim and text halos (at an opacity) | `#000000` | `#FFFFFF` | — | — |
| `voltaMapBackdrop` | map placeholder gradient | `#1B1E23` | `#E4E6EA` | — | — |
| `voltaTextPrimary` | primary text | `#FFFFFF` | `#111111` | 16.3:1 card, 17.9:1 page | 18.9:1 card, 16.9:1 page |
| `voltaTextSecondary` | secondary text | `#9E9E9E` | `#5E5E63` | 6.1:1 card, 6.7:1 page | 6.4:1 card, 5.8:1 page |
| `voltaTextTertiary` | tertiary text | `#888888` | `#6C6C70` | 4.6:1 card, 5.1:1 page | 5.2:1 card, 4.7:1 page |
| `voltaBlue` | selection, range, links | `#3B82F6` | `#2563EB` | 4.4:1 card, 4.9:1 page | 5.2:1 card, 4.6:1 page |
| `voltaBlueFill` | fill behind white labels | `#2563EB` | `#1D4ED8` | white 5.2:1 | white 6.7:1 |
| `voltaBlueText` | small blue text on a blue wash (pills, bordered buttons) | `#3B82F6` | `#1D4ED8` | as `voltaBlue` | 5.2:1 or better on a 12–18% wash |
| `voltaGreen` | charging, online, on | `#5ECB93` | `#157A3E` | 8.1:1 card, 8.9:1 page | 5.4:1 card, 4.8:1 page |
| `voltaAmber` | warm, warnings | `#F59E0B` | `#A84E0A` | 7.6:1 card, 8.3:1 page | 5.6:1 card, 5.0:1 page |
| `voltaRed` | alerts, errors, Sentry | `#EF4444` | `#C42B1C` | 4.3:1 card, 4.8:1 page | 5.7:1 card, 5.1:1 page |
| `voltaPurple` | regen, secondary series | `#A78BFA` | `#7C3AED` | 6.0:1 card, 6.6:1 page | 5.7:1 card, 5.1:1 page |
| `voltaTeal` | climate accent | `#14B8A6` | `#0F766E` | 6.5:1 card, 7.2:1 page | 5.5:1 card, 4.9:1 page |
| `NowCard.parkedText` | parked state text | `#60A5FA` | `#1D4ED8` | 6.4:1 card, 7.1:1 page | 6.7:1 card, 6.0:1 page |
| `ScreenKit.mint` | vehicle icons, "CURRENT" | `#4AC286` | `#1A7D49` | 7.3:1 card, 8.0:1 page | 5.2:1 card, 4.6:1 page |
| `DriveScoreTint.fair` | score 60–79 | `#F5BE62` | `#9A6200` | 9.6:1 card, 10.6:1 page | 5.1:1 card, 4.6:1 page |
| `DriveScoreTint.poor` | score < 60 | `#FF8178` | `#C4372A` | 6.7:1 card, 7.4:1 page | 5.3:1 card, 4.8:1 page |
| `LiveDrivingCard.staleAmber` | live drive, stale reading | `#FF9F0A` | `#A84E0A` | 7.9:1 card, 8.7:1 page | 5.6:1 card, 5.0:1 page |
| `LiveDrivingCard.noDataGray` | live drive, no data | `#8E8E93` | `#6C6C70` | 5.0:1 card, 5.5:1 page | 5.2:1 card, 4.7:1 page |
| More footer | "Volta · v1.0 · private" | `#9E9E9E` at 50% | `#6C6C70` | as on `main` | 4.7:1 page |
| `MileageTrackerView.pastBar` | unselected history bars | `#3B82F6` at 35% | `#6692F1` | as on `main` | 3.0:1 card |
| `IdleStateSlice` greys | sentry, climate, awake, asleep, unclassified | `#D6D6D6` `#B0B0B0` `#8A8A8A` `#6E6E6E` `#4A4A4A` | `#1C1C1E` `#3A3A3C` `#545458` `#6E6E73` `#8E8E93` | as on `main` | 17, 11.4, 7.5, 5.1, 3.3:1 card |
| `WTheme.labelDim` | widget "Updated" line | `#8A8F98` at 80% | `#6C6C70` | as on `main` | 5.2:1 on white |

In light mode the electricity-rate placeholders use `voltaTextTertiary` (the
system placeholder is about 1.7:1 on a white field), and the Siri snippet's
secondary lines use `voltaTextSecondary` (the system `.secondary` is about 3.4:1
on the light snippet glass). Dark mode keeps the system styles in both.

Shortfalls: in dark mode, `voltaBlue` (4.4:1) and `voltaRed` (4.3:1) are just
under 4.5:1 on the card. Those values come from `main` and are unchanged here,
because dark mode stays exactly as it was. Both meet 3:1 for graphics and large
text, and both reach 4.8:1 or better on the page. Every light value meets 4.5:1
on both the card and the page.

Gradients (`VoltaGradient`): charging is `#15803D → green → #A7F3D0` in dark
and `#0E5C2E → green → #34B866` in light. Range is `#2563EB → blue → #60A5FA`
in dark and `#1E40AF → blue → #4F8EF7` in light. `GradientGauge.daylight`
night is `#334155` in dark and `#94A3B8` in light, and dusk is `#A855F7` in
dark and `#9333EA` in light.

Shadows: dark cards have none; their fill separates them. Light cards get
`voltaCardShadow` (black 6 %, 6 pt blur, 2 pt down). Text over a map gets a
halo in `voltaMapWash`, black on the dark map and white on the light one, at
the opacity the dark shadow always had.

## Maps

`voltaBasemap()` is MapKit's muted standard style drained to grey, now in the
system appearance. `voltaMapDim` washes the tiles with `voltaMapWash`: black on
the dark map, white on the light map, at the same opacity. The Dashboard and
live-charging backdrops use `voltaBackdropMapTone()`, which keeps the dark
map's slight darkening and leaves the light map at its own brightness. The
fades into the page use `voltaBackground`, so they fade into whichever page is
showing. The Apple Maps credit placement is unchanged: hidden under the fade on
the Dashboard, Drives hero and Charging hero, and visible where it was before
on the other maps. The Places map in Settings keeps MapKit's muted standard
style with its colour, as it had on `main`, so it shows the light version of
that style in light mode.

Route colours (`RoutePalette`) have a dark-map and a light-map variant with the
same meaning, order and legend. The light variant keeps each hue and inverts
lightness: on the dark map a higher value is brighter, and on the light map it
is deeper, so in both modes it stands out more from the tiles. Within one
appearance, each colour still means one value. Casing is near-black `#101318`
under dark-map routes and a white halo under light-map ones. Start and end
markers are white on near-black in dark and `#1C1C1E` on white in light.

| Ramp | Dark map knots | Light map knots | Least contrast, light knots on light tiles (#F2F2F2 / #E3E3E3) |
|---|---|---|---|
| speed | `#7C8CFF` `#4BA8FF` `#39D8EE` `#9AEAC8` `#F3F5B0` | `#616BFC` `#0B7CD1` `#06808F` `#027E5B` `#7E5D02` | 3.7:1 / 3.3:1 |
| efficiency | `#5EEBC4` `#46B79C` `#A8B0BB` `#E9A34B` `#FF7A45` | `#097B62` `#088B73` `#778190` `#B0700E` `#BD4506` | 3.5:1 / 3.1:1 |
| elevation | `#7C8CFF` `#B2AEFF` `#F3D9FF` | `#5B62F8` `#5E4FB8` `#6B2B83` | 4.1:1 / 3.6:1 |
| density | `#6698DD` `#56B6EC` `#77DBED` `#F1F8FF` | `#3E7ACB` `#0571A0` `#015D6A` `#003760` | 3.9:1 / 3.4:1 |
| regen | `#B79CFF` | `#7449C5` | 5.4:1 / 4.7:1 |
| plain | `#4BA8FF` | `#0C74C4` | 4.4:1 / 3.8:1 |
| missing | `#6B7078` | `#939AA3` | 2.5:1 / 2.2:1 |


`missing` is intentionally quiet in both modes: it is a thinner line that
means "not recorded", and it sits below 3:1 on purpose, as it did on the dark
map (`#6B7078`).

## Widgets and Live Activities

- Home Screen widgets use `WTheme`, the extension's copy of the tokens, and
  follow the system in the default style. In the tinted and clear Home Screen
  styles the system draws every opaque pixel in one tint, so the status tiles'
  card fill becomes a faint `ink` wash there (`WCardBackground`); an opaque card
  would cover its text.
- A Live Activity's Lock Screen tint is resolved apart from the content's
  traits, so a dynamic colour there can disagree with the content.
  `WActivityChrome` reads the content's colour scheme and sets the tint and the
  system action colour to match. On the Lock Screen the system currently hands
  Live Activities its dark scheme in both appearances, so they stay dark there,
  as they were on `main`.
- Control Center controls are system-drawn glyphs with a `WTheme` tint.
- Siri and Shortcuts snippets use the app's tokens and system styles, and are
  drawn in the appearance current when the intent runs.

## Kept the same in both modes, by design

- The trip share card (`TripShareCard`) renders dark, so every shared image
  looks the same whoever sends it and whatever their appearance.
- Charger badges (`ChargerKind.fill`) and the Tesla red: they work like a charger
  network's sign, each on a white ring that reads on either map.
- Map markers: the car marker's white rim, the charging disc's green, the
  session pin colour, and the glyphs drawn on those fills.
- Text on saturated fills (`voltaOnAccent`, white): blue buttons and badge glyphs.
- Lock Screen accessory widgets draw in white; the system renders them vibrant
  and tints them.
- The Dynamic Island is always dark. The system resolves the dark values there.
- The app icon already has its own light, dark and tinted variants.

## Allowlisted scheme reads

- `AppleSignIn`: Apple's button takes a style, not a colour. It is white on
  dark and black on light, per Apple's guidelines.
- `voltaBackdropMapTone()`: brightness is a modifier, not a colour.
- `TripRouteCanvas` and `DrivesRouteMap` pass `RoutePalette.Appearance` to the
  ramp lookups. Those compute raw RGB for bucketing thousands of route pieces,
  where a dynamic colour per piece would cost too much.
