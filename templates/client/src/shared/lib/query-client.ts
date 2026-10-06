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

/**
 * App-wide keys. Each feature keeps its own key factory next to its hooks
 * (e.g. notesKeys in features/notes/use-notes.ts) and invalidates its `all` key
 * after any of its mutations.
 */
export const queryKeys = {
  me: ['me'] as const,
};
