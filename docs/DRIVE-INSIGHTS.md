# Drives: sources and derivations

The Drives screen uses recorded TeslaMate history and, when enabled, exactly VIN-digest-bound Fleet Telemetry. It never geocodes an address or sends a route to a directions service. MapKit supplies the existing base map; route geometry is drawn from API coordinates. Private reference images are not repository assets.

## Energy and consumption

1. TeslaMate start minus end rated range × its modal charge-derived car efficiency (fallback: `cars.efficiency`, kWh/km). If stored endpoint range is missing, use a rated-range position within 120 seconds of that endpoint. An interior reading does not stand in for a missing endpoint.
2. Fleet `LifetimeEnergyUsed` end minus start, when the counter does not decrease within the drive.
3. Fleet `EnergyRemaining` start minus end (a net battery-energy estimate, affected by regeneration and temperature).

Telemetry fallback requires a closed drive, two distinct finite observations within 120 seconds of both endpoints, exact current VIN digest binding, no known receiver gaps and no explicit invalid/conflicting observations of that signal. Negative deltas and unchanged coarse readings over a moving drive are unknown rather than a claim of zero use. A zero electricity rate remains a real free rate. Wh/km = kWh × 1000 ÷ positive distance; the app converts to Wh/mi using its existing unit preferences. `energySource` identifies the estimate. Missing evidence renders as unknown. Only the drive API is enriched; general analytics summaries keep their existing TeslaMate-only contract.

## Cost

Estimated cost = known nonnegative energy × rate. API rate is sum(cost) ÷ sum(energy added) of completed priced TeslaMate charges for that car before the drive, including free charges. Only positive charge energy and nonnegative cost participate. TeslaMate costs need the server's configured currency; without one, the app uses Settings' USD/kWh fallback. The new device-persisted setting defaults to $0.20/kWh and accepts zero for free energy. Real priced charges take precedence. All drive cards, totals and detail use this policy. The prior per-server/vehicle manual trip-rate editor is replaced by this USD Settings fallback; its saved rates remain stored but are not converted or used. The Settings editor explicitly explains this policy transition. Totals show currency amounts separately and disclose missing energy. This is an estimate, not a bill or a reconstruction of which charge powered a drive.

## Places and geometry

City label precedence: `addresses.city`, geofence name, `addresses.neighbourhood`, `addresses.name`; old servers fall back to the existing address label. Search includes cities and addresses. List geometry comes from TeslaMate positions, evenly sampled to at most 64 points per drive, with first/last points retained. Recording gaps over 120 seconds split the line, including when intermediate points are removed. Missing routes have an explicit empty state; no invented endpoint line. The overview shows loaded routes in the selected period/filter/search. Detail keeps the existing richer telemetry route and replay.

## Scores

**Efficiency v1** (list, card and detail ring): round(min(100, max(0, rated Wh/km ÷ actual Wh/km × 100))). Both inputs must be finite and positive. This is Volta's efficiency measure, not Wattly's proprietary algorithm. Rings are hidden without inputs. Period score is distance-weighted across known scores and states when some drives are unscored. Every score ring (Drives header, cards, detail) uses one band: 80 and above `#5ECB93`, 60–79 `#F5BE62`, below 60 `#FF8178`.

**Smoothness v1** (detail): the existing independent speed-derived score. Intervals must be 0.5–6 seconds, with ≥70% whole-drive speed coverage and ≥120 moving intervals above 5 km/h. Acceleration/braking parts are the time shares within 2.0/2.5 m/s²; the optional co-timed power part is the share within 15 kW/s. Their available parts' mean is scored 0–100. Hard events are consecutive runs ≥0.3g; max g is the greatest speed-derived acceleration magnitude. These values are omitted/withheld without the cadence gate, and truncated telemetry cannot satisfy it. This is longitudinal acceleration inferred from speeds, not a measured total g force.

## Roadtrips and heatmap

Roadtrips sort closed drives chronologically and chain nonoverlapping drives across stops of at most 120 minutes. A chain (including a single long drive) needs ≥100 km total distance. Open/invalid-end drives do not participate. This is a time-and-distance heuristic, not route matching or a claim about intent. The list opens chain details and individual drive details.

Heatmap groups drive start dates by the device's calendar/time zone. Each month has a weekday-aligned calendar grid; intensity is distance relative to the largest loaded day. Selecting a day opens its real drives. Roadtrips and heatmap use the current selection's loaded pages. Remaining pagination is explicitly disclosed; blank cells are never described as complete history when more pages remain. Device-local day boundaries match the drives list. No 3D replay is claimed.

The heatmap's map counts road density from the same loaded drives. Recorded positions lie on a fixed Web Mercator grid at zoom 20: each cell is 256 map points across, the same everywhere for every selection, so loading more pages never moves a cell. On the ground a cell is about 38 m × cos(latitude): 38 m at the equator, 30 m at 37°, 25 m at 50°, 19 m at 60°. Cell x wraps at the antimeridian and a segment crossing it takes the short way. Each cell counts the distinct drives that pass through it, so a drive counts once per cell however often it was sampled there or passed it. Each drive is evenly thinned to at most 400 positions before counting. Roads are drawn 4 pt over a 7 pt `#101318` casing at full opacity, in strokes coloured by count on a log scale, busiest on top. The legend is the trip map's strip, on the page between the Density / Efficiency switch and the map, with four fixed labels, 1 · 3 · 10 · 30+. The Efficiency mode colours each cell by the distance-weighted average of its drives' consumption ratio against the shared reference (below); a negative average is regen, and that legend shows the regen swatch. Counting runs off the main thread, is deterministic, and stops early when the selection changes; the map keeps the previous layer until a rebuild for the new drives, mode and reference finishes. The rebuild is keyed on each drive's route contents (a digest of every point's time, coordinate and break flag, cached per drive), its consumption and the reference, so correcting one interior point or a break flag rebuilds it.

The Drives hero map uses the same density colouring at 3 pt over a 5 pt casing. Both all-drives maps frame the loaded routes at least 24 pt below the bars, 32 pt from the sides and 24 pt above the fade (the taller heatmap also clears the attribution); the margins never give way, so the camera never shows more than the routes plus them. The area MapKit fits into is measured from MapKit itself, so framing and drawing agree with the tiles whatever safe area the map inherits (iPhone Duo's side strip, the status bar), and an equal fit is still re-applied after MapKit refits on a resize. Where the title sits on the map (iPhone Duo's inline title), the hero grows by the title's row so the routes keep their room.

## Route colours

One palette (`RoutePalette`) colours every route: the trip map, the Drives overview map, the heatmap, their legends and the drive-detail efficiency gauge. Ramps are interpolated in OKLab.

- **Speed**: fixed 0–130 km/h, clamped; `#7C8CFF` `#4BA8FF` `#39D8EE` `#9AEAC8` `#F3F5B0`. The legend's top label is an inequality ("80+ mph").
- **Efficiency**: consumption ÷ reference, 0.5×–1.75×; `#5EEBC4` `#46B79C` `#A8B0BB` (1.0×) `#E9A34B` `#FF7A45`. The reference is the drive's rated Wh/km (`ratedWhPerKm`, as for the efficiency ring); without one it is 160 Wh/km. The legend's tick reads "Rated 264 Wh/mi" or "Est. 257 Wh/mi" in the user's units, and the drive-detail gauge shows the estimated label when the reference isn't rated. On maps of many drives the reference is the most common rating among them. Regen is `#B79CFF`. On a single drive the line is coloured by consumption over a rolling window centred on each segment (energy ÷ distance, both integrated from recorded speed and power). The window is a twelfth of the trip's recorded length, at least 400 m and at most 2 km, chosen once per trip. It shrinks symmetrically near the ends of a run and covers the whole run when the run is shorter than the window. A window never crosses a position gap or a stretch without speed or power, which stays drawn as not recorded; stops are recorded data, so a window runs through them and counts their idle energy. Regen is decided on the windowed value, and a drawing piece never spans a lasting change between regen and consumption. A change of sign starts a new stretch only when the new sign persists for strictly more than half the window, by distance, every interval counted (exactly half a window does not persist; the comparison allows 1 mm of rounding); this holds however small the values and at a run's ends too, so a long, gentle net regen or a final descent still changes the side. A flip that doesn't persist never splits, however large, and joins its neighbours, shortest first. A run where no sign persists is one stretch on the side of its net mean (consumption at exactly zero). Splitting only places boundaries: each piece is coloured by its own distance-weighted windowed mean, negative as regen and otherwise on the ramp, never clamped, and a piece grows until that mean agrees with its stretch, so a descent shorter than a piece keeps its colour while noise around zero stays one colour. When stretches would exceed the drawing budget (160 pieces), the shortest merge first and the merged piece again takes its own mean; recorded and unrecorded runs never merge, so colour always covers exactly the recorded time. Only the line colour is averaged: the scrubber and every number stay raw, and the legend gives the trip's actual window ("Averaged over 0.9 mi").
- **Elevation**: the trip's own minimum to maximum, legend in real values; `#7C8CFF` `#B2AEFF` `#F3D9FF`.
- **Density**: `#6698DD` `#56B6EC` `#77DBED` `#F1F8FF` at 1, 3, 10, 30+ drives.
- Unrecorded metric: `#6B7078` at 3 pt. Position gaps stay dashed. Plain routes (Drives overview) are `#4BA8FF`.

The trip route is 5 pt over an 8 pt `#101318` casing with round ends; colour changes are square so a short stretch shows at its true length. Maps of many drives draw 3 pt over 5 pt, the heatmap 4 pt over 7 pt. No glow. The start is a white ring with a dark centre, the end a white dot with a dark edge (a ring with a dot when they coincide), the same small markers in the drive-detail place list and on cards.

The route legend is one strip on the page background, under the trip map (above the distance headline) and between the heatmap's switch and its map: the bar with its reference tick and end labels, the regen swatch trailing in Efficiency mode, and a caption line only when there is something to say. VoiceOver reads it as one sentence. Every map fades into the page over its last 40 pt. MapKit's logo and Legal link sit in the map's bottom leading corner about 8 pt above the fade, never under it or any dimming (the tiles' dim eases off above the attribution row). The two hero backdrops (Drives and Charging) are the exception: there the logo and link stay at the map's real bottom edge, under the fade and the page, with the framing unchanged. The route is fitted with at least 24 pt (plus the markers' reach) from the top controls, the attribution and the fade, so it fills the map; on a short map the top margin gives way first, and a frame too small for any margin falls back to the plain fit. Margins that clear something covering the map (the toolbar, iPhone Duo's tab strip) never give way; only the decorative rest does. The overview maps' VoiceOver labels include the legend sentence.

Every map uses one basemap (`voltaBasemap()`): flat, muted, no points of interest, dark, desaturated. Pins on the charging and charger maps are drawn above the map so their colours stay true, placed by MapKit's own projection. The camera frames every pin whole (badge and callout, as measured): at least 24 pt from the map's edges and the toolbar and 24 pt above the fade or attribution, 40 pt on the Charger Map card. These maps measure MapKit's fit area the same way as the drive maps, and refit when a place moves, not only when the set of pins changes. On iPhone Duo the tab strip is an obstruction for every map that runs under it: routes (casing included) and pins stay 32 pt inside its edge, measured from the strip's safe area. A callout sits above its pin unless it would come within 8 pt of another callout or pin; then below; otherwise only the badge shows, which stays tappable and carries the callout's text for VoiceOver. Busier places are placed first. Charger Map cards carry the place's badge beside its name. Every charger pin is a `ChargerBadge`; a place's kind comes from its recorded sessions when they all agree, and is the neutral unknown badge when they conflict or there are none. A DC session whose network wasn't recorded is missing evidence, not a conflict: it agrees with any DC kind. The place name is never used to guess. An active session uses the dashboard's charging marker: a 30 pt `#5ECB93` disc with a 2 pt `#101318` ring and a dark bolt, and one slow expanding ring while charging, which runs only while the scene is active and the marker is on screen (none under Reduce Motion).


## Deployment compatibility

Summary fields are optional and additive; old clients ignore them and new clients decode older APIs. Reapply `deploy/telemetry/sql/002_api_series.sql` before enabling lifetime fallback: the new lifetime column is appended to the read-only view. If a supplemental telemetry query fails, TeslaMate history still loads and the logger emits only a stable, nonsensitive error code. No migration or deployment was run on a real server for this change.

## Offline terrain provisioning

The API Compose service mounts `${ELEVATION_DEM_PATH:-/opt/volta-elevation}`
read-only at `/elevation` and sets `ELEVATION_DEM_DIR=/elevation`. Provision that
host directory before recreating the API. An empty directory keeps elevation
unknown. No download or coordinate service runs in the API.

On the database host, select distinct SRTM names from the car's recorded
locations using `floor(latitude)`/`floor(longitude)` and hemisphere prefixes.
Keep the resulting one-name-per-line manifest private and outside the checkout.
Run `server/scripts/fetch-elevation-tiles.sh <host-directory> --tiles-file
<private-manifest>` there. Only public tile object names go to the public Skadi
bucket. Tiles and manifests are excluded from git. The downloader validates
names and decoded file sizes, keeps valid existing tiles, and reports counts
without logging the selected region.

Drive detail returns the elevation series, full-profile `elevationMinM` and
`elevationMaxM`, and `elevationGainM`/`elevationLossM`. The app uses the optional
extrema for the min/max labels and shows the existing amber chart and ↑/↓ totals.
Older APIs still render using the series extrema.

## Regen prerequisite

PackVoltage and PackCurrent must be valid in the same payload. The SQL views
keep power and regen unknown until an operator records the physically verified
PackCurrent sign in `volta_telemetry.power_calibration` with source
`operator_live_gate` and a private evidence note. A profile re-push cannot fix
missing calibration. Never infer the sign from charger input power, and never
write an assumed sign merely to populate the UI. Because power is derived in
views, a verified calibration applies to retained samples without replay.

TeslaMate's recorded `positions.power` can contain negative drive power and
support a historical regen estimate where its cadence and coverage are adequate.
It has no stored per-drive regen-energy counter; coarse or missing power cannot
establish a Wattly total. This change adds no historical backfill or automatic
calibration.
