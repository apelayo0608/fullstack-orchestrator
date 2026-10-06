import type { Request, RequestHandler } from 'express';
import type { Actor } from '../../../application/policies/ownership.ts';
import { UnauthorizedError } from '../../../domain/errors.ts';

export interface SessionRecord {
  userId: string;
  role: Actor['role'];
  mfaVerified: boolean;
  expiresAt: Date;
}

/**
 * Server-side sessions. The cookie holds a 256-bit random token; the database
 * stores only SHA-256(token), so a DB leak does not leak live sessions.
 */
export interface SessionStore {
  get(rawToken: string): Promise<SessionRecord | null>;
}

/**
 * httpOnly + Secure + SameSite=Lax + Path=/ and no Domain (required by __Host-).
 * Browsers treat http://localhost as secure, so this works behind the Vite proxy too.
 */
export const SESSION_COOKIE = '__Host-sid';

export function requireAuth(sessions: SessionStore): RequestHandler {
  return async (req, _res, next) => {
    const token: unknown = req.cookies?.[SESSION_COOKIE];
    if (typeof token !== 'string' || token.length < 32) throw new UnauthorizedError();
    const session = await sessions.get(token);
    if (!session || session.expiresAt.getTime() <= Date.now()) throw new UnauthorizedError();
    req.actor = { userId: session.userId, role: session.role, mfaVerified: session.mfaVerified };
    next();
  };
}

export function actorOf(req: Request): Actor {
  if (!req.actor) throw new UnauthorizedError();
  return req.actor;
}
