export interface DataKey {
  id: string;
  key: Buffer;
}

export interface KeyRing {
  active(): DataKey;
  /** Throws UnknownKeyError for ids that are not loaded. */
  get(id: string): DataKey;
}

export class UnknownKeyError extends Error {
  constructor(id: string) {
    super(`unknown data key: ${id}`);
    this.name = 'UnknownKeyError';
  }
}

const KEY_ID = /^[A-Za-z0-9_-]{1,32}$/;

export function createKeyRing(keys: ReadonlyMap<string, Buffer>, activeId: string): KeyRing {
  const ring = new Map<string, DataKey>();
  for (const [id, key] of keys) {
    if (!KEY_ID.test(id)) throw new Error(`invalid data key id "${id}" (use [A-Za-z0-9_-], max 32)`);
    if (key.length !== 32) throw new Error(`data key "${id}" must be 32 bytes for AES-256`);
    ring.set(id, { id, key });
  }
  const active = ring.get(activeId);
  if (!active) throw new Error(`active data key "${activeId}" is not in the key ring`);

  return {
    active: () => active,
    get(id) {
      const found = ring.get(id);
      if (!found) throw new UnknownKeyError(id);
      return found;
    },
  };
}

/**
 * Loads AES-256 data keys from the environment:
 *   DATA_KEYS='{"k2026a":"<base64 of 32 random bytes>","k2025b":"..."}'
 *   DATA_ACTIVE_KEY='k2026a'
 * New key:  node -e "console.log(require('node:crypto').randomBytes(32).toString('base64'))"
 * Rotation: add a key, switch DATA_ACTIVE_KEY, run the re-encrypt job, then retire the old key.
 * Production keys come from a secrets manager or KMS, never from a committed file.
 */
export function keyRingFromEnv(env: NodeJS.ProcessEnv = process.env): KeyRing {
  const raw = env.DATA_KEYS;
  const activeId = env.DATA_ACTIVE_KEY;
  if (!raw || !activeId) throw new Error('DATA_KEYS and DATA_ACTIVE_KEY must be set');

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error('DATA_KEYS must be a JSON object of keyId -> base64 key');
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('DATA_KEYS must be a JSON object of keyId -> base64 key');
  }

  const keys = new Map<string, Buffer>();
  for (const [id, b64] of Object.entries(parsed)) {
    if (typeof b64 !== 'string') throw new Error(`data key "${id}" must be a base64 string`);
    keys.set(id, Buffer.from(b64, 'base64'));
  }
  return createKeyRing(keys, activeId);
}
