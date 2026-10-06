import type { Pool } from 'pg';
import type { FieldContext, FieldEncryptor } from '../../application/ports/field-encryptor.ts';
import type { Note, NoteInput } from '../../domain/notes/note.ts';
import type { NoteRepository } from '../../domain/notes/note.repository.ts';

interface NoteRow {
  id: string;
  owner_id: string;
  title: string;
  body_enc: string;
  created_at: Date;
  updated_at: Date;
}

const COLUMNS = 'id, owner_id, title, body_enc, created_at, updated_at';

/**
 * Pattern for every repository of user-owned data:
 *  - owner_id is in the WHERE clause of every SELECT, UPDATE and DELETE;
 *  - sensitive columns are encrypted here, at the persistence boundary;
 *  - the AAD binds each ciphertext to its row and owner.
 */
export class PgNoteRepository implements NoteRepository {
  readonly #db: Pool;
  readonly #crypto: FieldEncryptor;

  constructor(db: Pool, crypto: FieldEncryptor) {
    this.#db = db;
    this.#crypto = crypto;
  }

  #ctx(id: string, ownerId: string): FieldContext {
    return { table: 'notes', column: 'body_enc', rowId: id, ownerId };
  }

  #toNote(row: NoteRow): Note {
    return {
      id: row.id,
      ownerId: row.owner_id,
      title: row.title,
      body: this.#crypto.decrypt(row.body_enc, this.#ctx(row.id, row.owner_id)),
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  }

  async listForOwner(ownerId: string, limit: number): Promise<Note[]> {
    const { rows } = await this.#db.query<NoteRow>(
      `SELECT ${COLUMNS} FROM notes WHERE owner_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2`,
      [ownerId, limit],
    );
    return rows.map((row) => this.#toNote(row));
  }

  async findForOwner(id: string, ownerId: string): Promise<Note | null> {
    const { rows } = await this.#db.query<NoteRow>(
      `SELECT ${COLUMNS} FROM notes WHERE id = $1 AND owner_id = $2`,
      [id, ownerId],
    );
    return rows[0] ? this.#toNote(rows[0]) : null;
  }

  async create(note: Note): Promise<void> {
    await this.#db.query(
      `INSERT INTO notes (id, owner_id, title, body_enc, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6)`,
      [note.id, note.ownerId, note.title, this.#crypto.encrypt(note.body, this.#ctx(note.id, note.ownerId)), note.createdAt, note.updatedAt],
    );
  }

  async updateForOwner(id: string, ownerId: string, input: NoteInput): Promise<Note | null> {
    const { rows } = await this.#db.query<NoteRow>(
      `UPDATE notes SET title = $3, body_enc = $4, updated_at = now()
        WHERE id = $1 AND owner_id = $2
        RETURNING ${COLUMNS}`,
      [id, ownerId, input.title, this.#crypto.encrypt(input.body, this.#ctx(id, ownerId))],
    );
    return rows[0] ? this.#toNote(rows[0]) : null;
  }

  async deleteForOwner(id: string, ownerId: string): Promise<boolean> {
    const { rowCount } = await this.#db.query(`DELETE FROM notes WHERE id = $1 AND owner_id = $2`, [id, ownerId]);
    return (rowCount ?? 0) > 0;
  }
}
