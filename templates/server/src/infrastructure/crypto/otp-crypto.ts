import { createHmac, randomInt, timingSafeEqual } from 'node:crypto';
import type { OtpCrypto, Totp } from '../../application/mfa/mfa.ports.ts';
import { generateTotpSecret, otpauthUri, verifyTotp } from './totp.ts';

/**
 * 6-digit codes have only 10^6 values, so a plain SHA-256 is brute-forceable
 * from a DB leak. HMAC with a server-side pepper (OTP_PEPPER, 32+ random bytes,
 * kept outside the database) prevents that. Also used for recovery codes.
 */
export function createOtpCrypto(pepper: Buffer): OtpCrypto {
  if (pepper.length < 32) throw new Error('OTP_PEPPER must be at least 32 bytes');
  const hash = (code: string) => createHmac('sha256', pepper).update(code).digest('base64url');
  return {
    generateCode: () => randomInt(0, 1_000_000).toString().padStart(6, '0'),
    hash,
    verify(code, expected) {
      const a = Buffer.from(hash(code));
      const b = Buffer.from(expected);
      return a.length === b.length && timingSafeEqual(a, b);
    },
  };
}

export const rfc6238Totp: Totp = {
  generateSecret: generateTotpSecret,
  verify: (secret, code, nowMs) => verifyTotp(secret, code, nowMs, 1),
  uri: otpauthUri,
};
