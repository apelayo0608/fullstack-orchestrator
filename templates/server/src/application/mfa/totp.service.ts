import { NotFoundError } from '../../domain/errors.ts';
import type { FieldContext, FieldEncryptor } from '../ports/field-encryptor.ts';
import type { Actor } from '../policies/ownership.ts';
import type { MfaRepository, Totp } from './mfa.ports.ts';

export interface TotpServiceDeps {
  repo: MfaRepository;
  totp: Totp;
  crypto: FieldEncryptor;
  now: () => number;
  issuer: string;
}

const secretContext = (userId: string): FieldContext => ({ table: 'mfa_totp', column: 'secret_enc', rowId: userId, ownerId: userId });

export function makeTotpService({ repo, totp, crypto, now, issuer }: TotpServiceDeps) {
  return {
    /**
     * Step 1 of enrolment. The route must require a fresh re-authentication
     * (password or current factor within the last few minutes).
     * Returns the otpauth URI for the QR code; the secret is never returned again.
     */
    async beginEnrollment(actor: Actor, accountLabel: string): Promise<{ otpauthUri: string }> {
      const secret = totp.generateSecret();
      await repo.saveUnconfirmedTotp(actor.userId, crypto.encrypt(secret, secretContext(actor.userId)));
      return { otpauthUri: totp.uri(secret, accountLabel, issuer) };
    },

    /** Step 2: the user proves the authenticator works. Issue recovery codes after this succeeds. */
    async confirmEnrollment(actor: Actor, code: string): Promise<boolean> {
      const record = await repo.getTotp(actor.userId);
      if (!record || record.confirmed) throw new NotFoundError('totp_enrollment');
      const step = totp.verify(crypto.decrypt(record.secretEnc, secretContext(actor.userId)), code, now());
      if (step === null) return false;
      await repo.confirmTotp(actor.userId, step);
      return true;
    },

    /** Login / step-up check. Rejects codes from an already-used time step (replay). */
    async verify(userId: string, code: string): Promise<boolean> {
      const record = await repo.getTotp(userId);
      if (!record?.confirmed) return false;
      const step = totp.verify(crypto.decrypt(record.secretEnc, secretContext(userId)), code, now());
      if (step === null) return false;
      return repo.advanceTotpStep(userId, step);
    },
  };
}
