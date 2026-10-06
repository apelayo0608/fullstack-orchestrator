import type { RequestHandler } from 'express';
import { ForbiddenError } from '../../../domain/errors.ts';

const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);

/**
 * CSRF defence on top of SameSite cookies: state-changing requests must come
 * from an allowed origin. Browsers send Origin on every cross-origin request and
 * on same-origin POST/PUT/PATCH/DELETE, so the client needs no extra token.
 * Dev: allowedOrigins = ['http://localhost:5173'] (the Vite origin, not the API port).
 */
export function sameOriginWrites(allowedOrigins: readonly string[]): RequestHandler {
  const allowed = new Set(allowedOrigins);
  return (req, _res, next) => {
    if (SAFE_METHODS.has(req.method)) return next();
    const fetchSite = req.get('sec-fetch-site');
    const origin = req.get('origin');
    if (fetchSite === 'same-origin' || (origin !== undefined && allowed.has(origin))) return next();
    throw new ForbiddenError('bad_origin');
  };
}
