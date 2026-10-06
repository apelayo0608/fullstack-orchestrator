import { QueryClient } from '@tanstack/react-query';
import { ApiError } from './api-client';

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      // Retry network/5xx failures only; 4xx answers will not change on retry.
      retry: (failureCount, error) => !(error instanceof ApiError && error.status < 500) && failureCount < 2,
    },
    mutations: { retry: false },
  },
});

/** One factory per feature keeps invalidation precise: invalidate notes.all after any note mutation. */
const notesAll = ['notes'] as const;
export const queryKeys = {
  me: ['me'] as const,
  notes: {
    all: notesAll,
    list: () => [...notesAll, 'list'] as const,
    detail: (id: string) => [...notesAll, 'detail', id] as const,
  },
};
