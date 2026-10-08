// Bun >=1.4 provides native Temporal. TS 5.9 does not yet declare its globals;
// keep the small runtime surface used here typed without adding a polyfill.
type Instant = { toString(options: { fractionalSecondDigits: 3 }): string };
type ZonedDateTime = { startOfDay(): ZonedDateTime; subtract(duration: { days: number }): ZonedDateTime; toInstant(): Instant };
const { Temporal } = globalThis as typeof globalThis & {
  Temporal: { Instant: { from(value: string): { toZonedDateTimeISO(zone: string): ZonedDateTime } } };
};

export function summaryPeriod(now: Date, range: 'today' | '7d' | '30d', timeZone: string) {
  const local = Temporal.Instant.from(now.toISOString()).toZonedDateTimeISO(timeZone);
  const start = range === 'today' ? local.startOfDay() : local.subtract({ days: range === '7d' ? 7 : 30 });
  return { periodStart: start.toInstant().toString({ fractionalSecondDigits: 3 }), periodEnd: now.toISOString(), timeZone };
}
