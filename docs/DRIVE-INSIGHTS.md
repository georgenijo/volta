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

**Efficiency v1** (list, card and detail ring): round(min(100, max(0, rated Wh/km ÷ actual Wh/km × 100))). Both inputs must be finite and positive. This is Volta's efficiency measure, not Wattly's proprietary algorithm. Rings are hidden without inputs. Period score is distance-weighted across known scores and states when some drives are unscored.

**Smoothness v1** (detail): the existing independent speed-derived score. Intervals must be 0.5–6 seconds, with ≥70% whole-drive speed coverage and ≥120 moving intervals above 5 km/h. Acceleration/braking parts are the time shares within 2.0/2.5 m/s²; the optional co-timed power part is the share within 15 kW/s. Their available parts' mean is scored 0–100. Hard events are consecutive runs ≥0.3g; max g is the greatest speed-derived acceleration magnitude. These values are omitted/withheld without the cadence gate, and truncated telemetry cannot satisfy it. This is longitudinal acceleration inferred from speeds, not a measured total g force.

## Roadtrips and heatmap

Roadtrips sort closed drives chronologically and chain nonoverlapping drives across stops of at most 120 minutes. A chain (including a single long drive) needs ≥100 km total distance. Open/invalid-end drives do not participate. This is a time-and-distance heuristic, not route matching or a claim about intent. The list opens chain details and individual drive details.

Heatmap groups drive start dates by the device's calendar/time zone. Each month has a weekday-aligned calendar grid; intensity is distance relative to the largest loaded day. Selecting a day opens its real drives. Roadtrips and heatmap use the current selection's loaded pages. Remaining pagination is explicitly disclosed; blank cells are never described as complete history when more pages remain. Device-local day boundaries match the drives list. No route-density map or 3D replay is claimed.

## Deployment compatibility

Summary fields are optional and additive; old clients ignore them and new clients decode older APIs. Reapply `deploy/telemetry/sql/002_api_series.sql` before enabling lifetime fallback: the new lifetime column is appended to the read-only view. If a supplemental telemetry query fails, TeslaMate history still loads and the logger emits only a stable, nonsensitive error code. No migration or deployment was run on a real server for this change.
