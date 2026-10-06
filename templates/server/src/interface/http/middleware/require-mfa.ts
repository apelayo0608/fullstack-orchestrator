import type { RequestHandler } from 'express';
import { ForbiddenError, UnauthorizedError } from '../../../domain/errors.ts';

/**
 * Mount after requireAuth on every route except the login/MFA endpoints.
 * A session becomes mfaVerified only after a TOTP or email OTP check succeeds.
 */
export const requireMfa: RequestHandler = (req, _res, next) => {
  if (!req.actor) throw new UnauthorizedError();
  if (!req.actor.mfaVerified) throw new ForbiddenError('mfa_required');
  next();
};
