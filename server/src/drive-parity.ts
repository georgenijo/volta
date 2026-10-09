import type { Row } from './db';

/** Net energy, never clamped to zero: a negative delta is not a costable drive. */
export function applyDriveEnergy(row: Row, fallback?: { energy: number | null; source: string | null }) {
  const rated = row.energyUsedKwh;
  const energy = typeof rated === 'number' && Number.isFinite(rated) && (rated > 0 || (rated === 0 && row.distanceKm === 0)) ? rated : fallback?.energy ?? null;
  row.energyUsedKwh = energy;
  row.energySource = energy === null ? null : energy === rated ? 'teslamate_rated_range' : fallback?.source;
  row.efficiencyWhPerKm = energy !== null && row.distanceKm > 0 ? energy * 1000 / row.distanceKm : null;
  return row;
}

/** Efficiency v1, distinct from the detail's speed-derived Smoothness v1. */
export function efficiencyScore(whPerKm: number | null, ratedWhPerKm: number | null): number | null {
  if (whPerKm === null || ratedWhPerKm === null || !Number.isFinite(whPerKm) || !Number.isFinite(ratedWhPerKm)
    || whPerKm <= 0 || ratedWhPerKm <= 0) return null;
  return Math.round(Math.min(100, Math.max(0, ratedWhPerKm / whPerKm * 100)));
}

export function endpointEnergy(first: Row | undefined, last: Row | undefined, start: Date, end: Date): number | null {
  if (!first || !last || +last.t <= +first.t || +first.t - +start > 120000 || +end - +last.t > 120000) return null;
  const delta = first.value - last.value;
  return Number.isFinite(delta) && delta > 0 ? delta : null;
}
