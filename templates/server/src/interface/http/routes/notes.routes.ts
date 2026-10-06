import { Router } from 'express';
import { z } from 'zod';
import type { NoteUseCases } from '../../../application/notes/note.use-cases.ts';
import type { Note } from '../../../domain/notes/note.ts';
import { NotFoundError, ValidationError } from '../../../domain/errors.ts';
import { actorOf } from '../middleware/require-auth.ts';

// strictObject rejects unknown keys, so { ownerId, role, id } in a body is a 400, not a silent IDOR.
const NoteBody = z.strictObject({
  title: z.string().trim().min(1).max(200),
  body: z.string().max(20_000),
});
const ListQuery = z.strictObject({ limit: z.coerce.number().int().min(1).max(100).optional() });
const IdParam = z.uuid();

function parseBody<T>(schema: z.ZodType<T>, input: unknown): T {
  const result = schema.safeParse(input);
  if (!result.success) {
    throw new ValidationError(result.error.issues.map((i) => ({ path: i.path.join('.'), message: i.message })));
  }
  return result.data;
}

/** A malformed id is just another id you cannot see: 404, never a 500 from Postgres. */
function parseId(raw: string | undefined): string {
  const result = IdParam.safeParse(raw);
  if (!result.success) throw new NotFoundError('note');
  return result.data;
}

/** Response DTO: explicit fields only. Never res.json() a raw DB row. */
const toDto = (n: Note) => ({ id: n.id, title: n.title, body: n.body, createdAt: n.createdAt, updatedAt: n.updatedAt });

/** Mount as: app.use('/api/notes', requireAuth(sessions), requireMfa, notesRouter(useCases)) */
export function notesRouter(notes: NoteUseCases): Router {
  const router = Router();

  router.get('/', async (req, res) => {
    const { limit } = parseBody(ListQuery, req.query);
    res.json((await notes.list(actorOf(req), limit)).map(toDto));
  });

  router.get('/:id', async (req, res) => {
    res.json(toDto(await notes.get(actorOf(req), parseId(req.params.id))));
  });

  router.post('/', async (req, res) => {
    res.status(201).json(toDto(await notes.create(actorOf(req), parseBody(NoteBody, req.body))));
  });

  router.patch('/:id', async (req, res) => {
    res.json(toDto(await notes.update(actorOf(req), parseId(req.params.id), parseBody(NoteBody, req.body))));
  });

  router.delete('/:id', async (req, res) => {
    await notes.remove(actorOf(req), parseId(req.params.id));
    res.status(204).end();
  });

  return router;
}
