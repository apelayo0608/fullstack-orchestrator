export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly issues: ReadonlyArray<{ path: string; message: string }> | undefined;

  constructor(status: number, code: string, issues?: ReadonlyArray<{ path: string; message: string }>) {
    super(code);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
    this.issues = issues;
  }
}

let onUnauthorized: () => void = () => {};
/** Called on any 401, e.g. clear the query cache and route to /login. */
export function setUnauthorizedHandler(handler: () => void) {
  onUnauthorized = handler;
}

interface RequestOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  body?: unknown;
  signal?: AbortSignal;
}

/**
 * Relative /api URLs go through the Vite proxy in dev and the reverse proxy in prod.
 * Auth is the httpOnly session cookie: no tokens in JS, localStorage, or Zustand.
 */
export async function api<T>(path: string, { method = 'GET', body, signal }: RequestOptions = {}): Promise<T> {
  const init: RequestInit = { method, credentials: 'same-origin' };
  if (signal) init.signal = signal;
  if (body !== undefined) {
    init.headers = { 'Content-Type': 'application/json' };
    init.body = JSON.stringify(body);
  }
  const res = await fetch(`/api${path}`, init);

  if (res.status === 204) return undefined as T;
  const data: unknown = await res.json().catch(() => null);

  if (!res.ok) {
    if (res.status === 401) onUnauthorized();
    const payload = (data ?? {}) as { error?: string; issues?: ReadonlyArray<{ path: string; message: string }> };
    throw new ApiError(res.status, payload.error ?? 'request_failed', payload.issues);
  }
  return data as T;
}
