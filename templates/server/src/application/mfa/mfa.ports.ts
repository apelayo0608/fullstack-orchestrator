export interface TotpRecord {
  /** AES-256-GCM envelope, context { table: 'mfa_totp', column: 'secret_enc', rowId: userId, ownerId: userId } */
  secretEnc: string;
  confirmed: boolean;
}

export interface EmailOtpRecord {
  id: string;
  codeHash: string;
  attempts: number;
  expiresAt: Date;
}

export interface MfaRepository {
  getTotp(userId: string): Promise<TotpRecord | null>;
  /** Upsert an unconfirmed secret (replaces any previous unconfirmed one). */
  saveUnconfirmedTotp(userId: string, secretEnc: string): Promise<void>;
  confirmTotp(userId: string, step: number): Promise<void>;
  /** Atomic: UPDATE ... SET last_step = $step WHERE user_id = $1 AND (last_step IS NULL OR last_step < $step). False = replay. */
  advanceTotpStep(userId: string, step: number): Promise<boolean>;

  /** Inserts a new code and marks every earlier unconsumed code for the user as consumed. */
  createEmailOtp(record: { id: string; userId: string; codeHash: string; expiresAt: Date }): Promise<void>;
  /** Latest unconsumed code for the user, or null. */
  getActiveEmailOtp(userId: string): Promise<EmailOtpRecord | null>;
  /** Atomic increment; returns the new attempt count. */
  incrementEmailOtpAttempts(id: string): Promise<number>;
  /** Atomic: UPDATE ... SET consumed_at = now() WHERE id = $1 AND consumed_at IS NULL. False if already used. */
  consumeEmailOtp(id: string): Promise<boolean>;
}

export interface Totp {
  generateSecret(): string;
  /** Matched time step, or null. */
  verify(secret: string, code: string, nowMs: number): number | null;
  uri(secret: string, accountLabel: string, issuer: string): string;
}

/** One-time codes: generation plus keyed hashing (HMAC with a server-side pepper). */
export interface OtpCrypto {
  generateCode(): string;
  hash(code: string): string;
  verify(code: string, hash: string): boolean;
}

export interface Mailer {
  sendOtp(to: string, code: string): Promise<void>;
}
