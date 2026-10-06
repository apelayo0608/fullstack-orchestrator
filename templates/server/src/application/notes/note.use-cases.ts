import { NotFoundError } from '../../domain/errors.ts';
import type { Note, NoteInput } from '../../domain/notes/note.ts';
import type { NoteRepository } from '../../domain/notes/note.repository.ts';
import { found, type Actor } from '../policies/ownership.ts';

export interface NoteUseCaseDeps {
  notes: NoteRepository;
  now: () => Date;
  /** UUIDv7 recommended (time-ordered); generated here so the id is known before encryption. */
  newId: () => string;
}

export type NoteUseCases = ReturnType<typeof makeNoteUseCases>;

export function makeNoteUseCases({ notes, now, newId }: NoteUseCaseDeps) {
  return {
    list: (actor: Actor, limit = 50) => notes.listForOwner(actor.userId, Math.min(Math.max(limit, 1), 100)),

    get: async (actor: Actor, id: string): Promise<Note> => found(await notes.findForOwner(id, actor.userId), 'note'),

    create: async (actor: Actor, input: NoteInput): Promise<Note> => {
      const at = now();
      // ownerId always comes from the actor, never from input.
      const note: Note = { id: newId(), ownerId: actor.userId, ...input, createdAt: at, updatedAt: at };
      await notes.create(note);
      return note;
    },

    update: async (actor: Actor, id: string, input: NoteInput): Promise<Note> =>
      found(await notes.updateForOwner(id, actor.userId, input), 'note'),

    remove: async (actor: Actor, id: string): Promise<void> => {
      if (!(await notes.deleteForOwner(id, actor.userId))) throw new NotFoundError('note');
    },
  };
}
