/**
 * Where an encrypted value lives. Becomes the AES-GCM additional authenticated
 * data, so a ciphertext copied into another row, column or owner fails to decrypt.
 * Generate rowId in the application (crypto.randomUUID) before INSERT so it is
 * known at encryption time.
 */
export interface FieldContext {
  table: string;
  column: string;
  rowId: string;
  ownerId: string;
}

export interface FieldEncryptor {
  encrypt(plaintext: string, ctx: FieldContext): string;
  /** Throws DecryptionError on tampering, wrong context, or unknown key. */
  decrypt(envelope: string, ctx: FieldContext): string;
  /** True when the envelope was written with a key other than the active one. */
  needsRotation(envelope: string): boolean;
}
