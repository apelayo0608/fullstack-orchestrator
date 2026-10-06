export interface Note {
  id: string;
  ownerId: string;
  title: string;
  /** Plaintext in the domain; encrypted only at the persistence boundary. */
  body: string;
  createdAt: Date;
  updatedAt: Date;
}

export type NoteInput = Pick<Note, 'title' | 'body'>;
