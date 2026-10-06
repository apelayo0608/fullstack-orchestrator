import cookieParser from 'cookie-parser';
import express, { type Express } from 'express';
import { rateLimit } from 'express-rate-limit';
import helmet from 'helmet';
import type { NoteUseCases } from '../../application/notes/note.use-cases.ts';
import { errorHandler } from './middleware/error-handler.ts';
import { requireAuth, type SessionStore } from './middleware/require-auth.ts';
import { requireMfa } from './middleware/require-mfa.ts';
import { sameOriginWrites } from './middleware/same-origin-writes.ts';
import { notesRouter } from './routes/notes.routes.ts';

export interface AppDeps {
  sessions: SessionStore;
  notes: NoteUseCases;
  /** Origins allowed to send state-changing requests, e.g. ['http://localhost:5173']. */
  appOrigins: readonly string[];
}

/** Built by the composition root (src/main.ts), which wires infrastructure into use cases. */
export function createApp({ sessions, notes, appOrigins }: AppDeps): Express {
  const app = express();
  app.disable('x-powered-by');
  // Behind a real reverse proxy in production, set app.set('trust proxy', 1) so rate limits see client IPs.

  app.use(helmet());
  app.use(express.json({ limit: '100kb' }));
  app.use(cookieParser());
  app.use('/api', rateLimit({ windowMs: 60_000, limit: 300, standardHeaders: 'draft-8', legacyHeaders: false }));
  app.use('/api', sameOriginWrites(appOrigins));

  // Auth routes (/api/auth/login, /api/auth/mfa/*) get a much stricter limiter, e.g. 10 / 15 min per IP + account.
  app.use('/api/notes', requireAuth(sessions), requireMfa, notesRouter(notes));

  app.use('/api', (_req, res) => void res.status(404).json({ error: 'not_found' }));
  app.use(errorHandler);
  return app;
}
