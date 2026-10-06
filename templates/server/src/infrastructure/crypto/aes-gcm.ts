import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import type { FieldContext, FieldEncryptor } from '../../application/ports/field-encryptor.ts';
import type { KeyRing } from './key-ring.ts';

const ALGORITHM = 'aes-256-gcm';
const VERSION = 'v1';
const IV_BYTES = 12; // 96-bit random nonce, fresh for every encryption
const TAG_BYTES = 16;

export class DecryptionError extends Error {
  constructor() {
    // Deliberately vague: never reveal whether the key, tag or context was wrong.
    super('decryption failed');
    this.name = 'DecryptionError';
  }
}

/** Unambiguous AAD encoding; JSON avoids delimiter collisions between parts. */
function additionalData(ctx: FieldContext): Buffer {
  const parts = [VERSION, ctx.table, ctx.column, ctx.rowId, ctx.ownerId];
  if (parts.some((p) => typeof p !== 'string' || p.length === 0)) {
    throw new Error('encryption context requires table, column, rowId and ownerId');
  }
  return Buffer.from(JSON.stringify(parts), 'utf8');
}

/**
 * AES-256-GCM field encryption.
 * Envelope (text column): v1.<keyId>.<iv>.<tag>.<ciphertext>, parts base64url.
 * With random 96-bit IVs, keep each key under ~2^32 encryptions; rotate long before.
 */
export class AesGcmFieldEncryptor implements FieldEncryptor {
  readonly #keys: KeyRing;

  constructor(keys: KeyRing) {
    this.#keys = keys;
  }

  encrypt(plaintext: string, ctx: FieldContext): string {
    const { id, key } = this.#keys.active();
    const iv = randomBytes(IV_BYTES);
    const cipher = createCipheriv(ALGORITHM, key, iv, { authTagLength: TAG_BYTES });
    cipher.setAAD(additionalData(ctx));
    const ciphertext = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
    const tag = cipher.getAuthTag();
    return [VERSION, id, iv.toString('base64url'), tag.toString('base64url'), ciphertext.toString('base64url')].join('.');
  }

  decrypt(envelope: string, ctx: FieldContext): string {
    const parts = envelope.split('.');
    if (parts.length !== 5 || parts[0] !== VERSION) throw new DecryptionError();
    const [, keyId, ivPart, tagPart, ctPart] = parts as [string, string, string, string, string];

    const iv = Buffer.from(ivPart, 'base64url');
    const tag = Buffer.from(tagPart, 'base64url');
    if (iv.length !== IV_BYTES || tag.length !== TAG_BYTES) throw new DecryptionError();

    try {
      const { key } = this.#keys.get(keyId);
      const decipher = createDecipheriv(ALGORITHM, key, iv, { authTagLength: TAG_BYTES });
      decipher.setAAD(additionalData(ctx));
      decipher.setAuthTag(tag);
      return Buffer.concat([decipher.update(Buffer.from(ctPart, 'base64url')), decipher.final()]).toString('utf8');
    } catch {
      throw new DecryptionError();
    }
  }

  needsRotation(envelope: string): boolean {
    return envelope.split('.')[1] !== this.#keys.active().id;
  }
}
