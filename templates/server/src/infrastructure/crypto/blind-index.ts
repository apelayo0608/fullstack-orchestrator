import { createHmac } from 'node:crypto';

/**
 * Deterministic HMAC-SHA256 "blind index" so encrypted columns can still be
 * looked up by equality (e.g. find user by email) without storing plaintext.
 * Uses its own key (BLIND_INDEX_KEY, 32+ random bytes), never a DATA_KEYS entry.
 * Store it in a separate <column>_bidx column with a unique index where needed.
 */
export function createBlindIndexer(key: Buffer) {
  if (key.length < 32) throw new Error('BLIND_INDEX_KEY must be at least 32 bytes');
  return function blindIndex(purpose: string, normalizedValue: string): string {
    return createHmac('sha256', key).update(purpose).update('\0').update(normalizedValue).digest('base64url');
  };
}

export const normalizeEmail = (email: string) => email.trim().toLowerCase();
