import type { Actor } from '../../application/policies/ownership.ts';

declare global {
  namespace Express {
    interface Request {
      /** Set only by requireAuth. Handlers read it through actorOf(req). */
      actor?: Actor;
    }
  }
}

export {};
