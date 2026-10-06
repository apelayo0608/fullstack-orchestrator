import type { ErrorRequestHandler } from 'express';
import { ForbiddenError, NotFoundError, UnauthorizedError, ValidationError } from '../../../domain/errors.ts';

/** Last middleware. Maps domain errors to HTTP; never leaks stacks, SQL, or plaintext. */
export const errorHandler: ErrorRequestHandler = (err, req, res, _next) => {
  if (err instanceof NotFoundError) return void res.status(404).json({ error: 'not_found' });
  if (err instanceof UnauthorizedError) return void res.status(401).json({ error: 'unauthorized' });
  if (err instanceof ForbiddenError) return void res.status(403).json({ error: err.code });
  if (err instanceof ValidationError) return void res.status(400).json({ error: 'validation_failed', issues: err.issues });
  // Malformed JSON or an oversized body from express.json()
  if (err?.type === 'entity.parse.failed') return void res.status(400).json({ error: 'invalid_json' });
  if (err?.type === 'entity.too.large') return void res.status(413).json({ error: 'payload_too_large' });

  // DecryptionError lands here too: it means tampering or a key problem, so alert on it.
  console.error(JSON.stringify({ level: 'error', msg: 'unhandled', name: err?.name, method: req.method, path: req.path }));
  res.status(500).json({ error: 'internal_error' });
};
