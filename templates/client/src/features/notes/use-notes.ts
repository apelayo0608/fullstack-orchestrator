import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '@/shared/lib/api-client';

/** Mirrors the API response DTO (toDto in notes.routes.ts). Dates arrive as ISO strings. */
export interface Note {
  id: string;
  title: string;
  body: string;
  createdAt: string;
  updatedAt: string;
}

export type NoteInput = Pick<Note, 'title' | 'body'>;

/** Key factory for this feature: invalidate notesKeys.all after any note mutation. */
const notesAll = ['notes'] as const;
export const notesKeys = {
  all: notesAll,
  list: () => [...notesAll, 'list'] as const,
  detail: (id: string) => [...notesAll, 'detail', id] as const,
};

export function useNotes() {
  return useQuery({
    queryKey: notesKeys.list(),
    queryFn: ({ signal }) => api<Note[]>('/notes', { signal }),
  });
}

export function useNote(id: string) {
  return useQuery({
    queryKey: notesKeys.detail(id),
    queryFn: ({ signal }) => api<Note>(`/notes/${encodeURIComponent(id)}`, { signal }),
  });
}

export function useCreateNote() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (input: NoteInput) => api<Note>('/notes', { method: 'POST', body: input }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: notesKeys.list() }),
  });
}

export function useUpdateNote() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...input }: NoteInput & { id: string }) =>
      api<Note>(`/notes/${encodeURIComponent(id)}`, { method: 'PATCH', body: input }),
    onSuccess: (note) => {
      queryClient.setQueryData(notesKeys.detail(note.id), note);
      return queryClient.invalidateQueries({ queryKey: notesKeys.list() });
    },
  });
}

export function useDeleteNote() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => api<void>(`/notes/${encodeURIComponent(id)}`, { method: 'DELETE' }),
    onSuccess: (_data, id) => {
      queryClient.removeQueries({ queryKey: notesKeys.detail(id) });
      return queryClient.invalidateQueries({ queryKey: notesKeys.list() });
    },
  });
}
