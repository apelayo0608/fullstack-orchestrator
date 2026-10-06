import { useMutation, useQueryClient } from '@tanstack/react-query';
import { api } from '@/shared/lib/api-client';
import { queryKeys } from '@/shared/lib/query-client';
import type { MfaMethod } from './use-login';

/** Sends a 6-digit code to the account's email. The server picks the address; the client never sends it. */
export function useSendEmailOtp() {
  return useMutation({
    mutationFn: () => api<void>('/auth/mfa/email/send', { method: 'POST' }),
  });
}

/** Step 2: upgrades the mfa_pending session to a full session, then refetches the user. */
export function useVerifyMfa() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (input: { method: MfaMethod; code: string }) =>
      api<void>('/auth/mfa/verify', { method: 'POST', body: input }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: queryKeys.me }),
  });
}
