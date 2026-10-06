import type { Mailer, MfaRepository, OtpCrypto } from './mfa.ports.ts';

export interface EmailOtpServiceDeps {
  repo: MfaRepository;
  otp: OtpCrypto;
  mailer: Mailer;
  now: () => number;
  newId: () => string;
}

const TTL_MS = 10 * 60_000;
const MAX_ATTEMPTS = 5;

export function makeEmailOtpService({ repo, otp, mailer, now, newId }: EmailOtpServiceDeps) {
  return {
    /**
     * Sends a fresh 6-digit code and invalidates older ones.
     * Rate-limit the route per user and per IP (e.g. 3 sends / 15 min).
     * `email` is the decrypted address of the user in the mfa_pending session, never a request field.
     */
    async issue(userId: string, email: string): Promise<void> {
      const code = otp.generateCode();
      await repo.createEmailOtp({ id: newId(), userId, codeHash: otp.hash(code), expiresAt: new Date(now() + TTL_MS) });
      await mailer.sendOtp(email, code);
    },

    /** Single use, expires after 10 minutes, dead after 5 wrong attempts. */
    async verify(userId: string, code: string): Promise<boolean> {
      if (!/^\d{6}$/.test(code)) return false;
      const record = await repo.getActiveEmailOtp(userId);
      if (!record || record.expiresAt.getTime() <= now()) return false;
      // Count the attempt before comparing so parallel guesses cannot exceed the limit.
      if ((await repo.incrementEmailOtpAttempts(record.id)) > MAX_ATTEMPTS) return false;
      if (!otp.verify(code, record.codeHash)) return false;
      return repo.consumeEmailOtp(record.id);
    },
  };
}
