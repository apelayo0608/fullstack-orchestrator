import { useMutation, useQuery } from '@tanstack/react-query';
import { api, ApiError } from '@/shared/lib/api-client';
import { queryKeys } from '@/shared/lib/query-client';

export type MfaMethod = 'totp' | 'email';

export interface Me {
  id: string;
  email: string;
  mfa: { totpEnrolled: boolean };
}

/** Current user, or null when signed out (401) or still MFA-pending (403 mfa_required). */
export function useMe() {
  return useQuery({
    queryKey: queryKeys.me,
    queryFn: async ({ signal }) => {
      try {
        return await api<Me>('/auth/me', { signal });
      } catch (err) {
        if (err instanceof ApiError && (err.status === 401 || err.status === 403)) return null;
        throw err;
      }
    },
  });
}

/**
 * Step 1: password. Every login needs a second factor, so success always means
 * "MFA pending": the server sets a short-lived mfa_pending session cookie and
 * lists the methods this user can use (TOTP if enrolled, email OTP always).
 */
export function useLogin() {
  return useMutation({
    mutationFn: (input: { email: string; password: string }) =>
      api<{ methods: MfaMethod[] }>('/auth/login', { method: 'POST', body: input }),
  });
}
