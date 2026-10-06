import type { Note, NoteInput } from './note.ts';

/**
 * Every method takes the owner and filters by it inside the query.
 * There is deliberately no findById(id): an unscoped lookup reachable from an
 * HTTP handler is how IDOR happens. Admin tooling gets its own, separately
 * authorized repository.
 */
export interface NoteRepository {
  listForOwner(ownerId: string, limit: number): Promise<Note[]>;
  findForOwner(id: string, ownerId: string): Promise<Note | null>;
  create(note: Note): Promise<void>;
  updateForOwner(id: string, ownerId: string, input: NoteInput): Promise<Note | null>;
  deleteForOwner(id: string, ownerId: string): Promise<boolean>;
}
