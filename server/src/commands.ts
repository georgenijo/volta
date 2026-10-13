import { ApiError } from './errors';

export const commandNames = [
  'lock', 'unlock', 'climate_on', 'climate_off', 'set_temps',
  'charge_start', 'charge_stop', 'set_charge_limit', 'open_charge_port',
  'close_charge_port', 'actuate_trunk', 'window_control', 'honk', 'flash',
  'sentry_on', 'sentry_off', 'trigger_homelink', 'wake_up', 'seat_heater',
  'steering_wheel_heat', 'defrost',
] as const;

export type CommandName = typeof commandNames[number];
export type CommandParams = Record<string, boolean | number | string>;
export type CommandCapabilityReason = 'commands_unavailable' | 'authorization_required' |
  'reauthorization_required' | 'command_scope_required' | 'vehicle_not_found' | 'stub_mode';
export type CommandCapability = { available: boolean; reason: CommandCapabilityReason | null; commands: CommandName[] };

const names = new Set<string>(commandNames);
const empty = new Set<CommandName>([
  'lock', 'unlock', 'climate_on', 'climate_off', 'charge_start', 'charge_stop',
  'open_charge_port', 'close_charge_port', 'honk', 'flash', 'sentry_on',
  'sentry_off', 'wake_up',
]);
const invalidCommand = () => new ApiError(400, 'invalid_command', 'Command is not supported');
const invalidParams = () => new ApiError(400, 'invalid_params', 'Expected the documented flat JSON parameters');

export function commandName(value: string): CommandName {
  if (!names.has(value)) throw invalidCommand();
  return value as CommandName;
}

export function idempotencyKey(value: string | undefined) {
  if (!value || !/^[A-Za-z0-9_-]{16,128}$/.test(value)) {
    throw new ApiError(400, 'idempotency_key_required', 'Idempotency-Key must be 16-128 URL-safe characters');
  }
  return value;
}

// JSON.parse silently keeps only the last duplicate. Scan and decode each
// top-level key first so escaped spellings of the same key are also rejected.
function duplicateTopLevelKey(text: string) {
  let i = 0;
  const whitespace = () => { while (/\s/.test(text[i] ?? '')) i++; };
  const stringEnd = () => {
    if (text[i] !== '"') return -1;
    for (let j = i + 1; j < text.length; j++) {
      if (text[j] === '\\') { j++; continue; }
      if (text[j] === '"') return j + 1;
    }
    return -1;
  };
  whitespace();
  if (text[i++] !== '{') return false;
  const seen = new Set<string>();
  while (true) {
    whitespace();
    if (text[i] === '}') return false;
    const end = stringEnd();
    if (end < 0) return false;
    let key: unknown;
    try { key = JSON.parse(text.slice(i, end)); } catch { return false; }
    if (typeof key !== 'string') return false;
    if (seen.has(key)) return true;
    seen.add(key); i = end; whitespace();
    if (text[i++] !== ':') return false;
    let depth = 0, quoted = false;
    for (; i < text.length; i++) {
      const char = text[i]!;
      if (quoted) {
        if (char === '\\') i++;
        else if (char === '"') quoted = false;
        continue;
      }
      if (char === '"') quoted = true;
      else if (char === '{' || char === '[') depth++;
      else if (char === '}' || char === ']') {
        if (depth === 0) break;
        depth--;
      } else if (char === ',' && depth === 0) break;
    }
    if (text[i] === ',') { i++; continue; }
    if (text[i] === '}') return false;
    return false;
  }
}

const exact = (body: Record<string, unknown>, keys: string[]) => {
  const actual = Object.keys(body).sort();
  return actual.length === keys.length && actual.every((key, index) => key === [...keys].sort()[index]);
};
const finite = (value: unknown, min: number, max: number) => typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max;

export function commandParams(name: CommandName, text: string): CommandParams {
  if (duplicateTopLevelKey(text)) throw invalidParams();
  let value: unknown;
  try { value = JSON.parse(text); } catch { throw invalidParams(); }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw invalidParams();
  const body = value as Record<string, unknown>;
  if (empty.has(name)) {
    if (!exact(body, [])) throw invalidParams();
  } else if (name === 'set_temps') {
    if (!exact(body, ['driverTempC', 'passengerTempC']) || !finite(body.driverTempC, 15, 28) || !finite(body.passengerTempC, 15, 28)) throw invalidParams();
  } else if (name === 'set_charge_limit') {
    if (!exact(body, ['percent']) || !finite(body.percent, 50, 100) || !Number.isInteger(body.percent)) throw invalidParams();
  } else if (name === 'actuate_trunk') {
    if (!exact(body, ['whichTrunk']) || !['front', 'rear'].includes(body.whichTrunk as string)) throw invalidParams();
  } else if (name === 'window_control') {
    if (!exact(body, ['command']) || !['vent', 'close'].includes(body.command as string)) throw invalidParams();
  } else if (name === 'trigger_homelink') {
    if (!exact(body, ['latitude', 'longitude']) || !finite(body.latitude, -90, 90) || !finite(body.longitude, -180, 180)) throw invalidParams();
  } else if (name === 'seat_heater') {
    if (!exact(body, ['heater', 'level']) || !finite(body.heater, 0, 5) || !Number.isInteger(body.heater) || !finite(body.level, 0, 3) || !Number.isInteger(body.level)) throw invalidParams();
  } else if (name === 'steering_wheel_heat' || name === 'defrost') {
    if (!exact(body, ['on']) || typeof body.on !== 'boolean') throw invalidParams();
  } else {
    throw invalidCommand();
  }
  return body as CommandParams;
}

export function commandCapability(value: unknown): CommandCapability | null {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return null;
  const body = value as Record<string, unknown>;
  if (!exact(body, ['available', 'reason', 'commands']) || typeof body.available !== 'boolean' || !Array.isArray(body.commands)) return null;
  const commands = body.commands;
  if (!commands.every(item => typeof item === 'string' && names.has(item)) || new Set(commands).size !== commands.length) return null;
  if (body.available === true) {
    if (body.reason !== null || commands.length === 0) return null;
    return { available: true, reason: null, commands: commands as CommandName[] };
  }
  const reasons = new Set<CommandCapabilityReason>(['commands_unavailable', 'authorization_required', 'reauthorization_required', 'command_scope_required', 'vehicle_not_found', 'stub_mode']);
  if (!reasons.has(body.reason as CommandCapabilityReason) || commands.length !== 0) return null;
  return { available: false, reason: body.reason as CommandCapabilityReason, commands: [] };
}
