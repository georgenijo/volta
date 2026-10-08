import postgres from 'postgres';

export function connect(url: string, readOnly = false, statementTimeout = 15000) {
  return postgres(url, {
    onnotice: () => {}, max: 5, idle_timeout: 20, connect_timeout: 5,
    connection: { timezone: 'UTC', statement_timeout: statementTimeout, ...(readOnly ? { default_transaction_read_only: true } : {}) },
    // TeslaMate decimals are metric measurements; JSON numbers match Swift Double.
    types: {
      numeric: { to: 1700, from: [1700], serialize: String, parse: Number },
      // Default postgres.js timestamp serialization routes strings through Date,
      // truncating microseconds. Preserve validated timestamp strings for cursors.
      timestamp: { to: 1114, from: [1114], serialize: (value: string | Date) => value instanceof Date ? value.toISOString() : value,
        parse: (value: string) => new Date(value.replace(' ', 'T') + (value.endsWith('Z') ? '' : 'Z')) },
    },
  });
}
export type DB = ReturnType<typeof connect>;
export type Row = Record<string, any>;
export function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}
