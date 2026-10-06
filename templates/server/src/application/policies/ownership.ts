import { NotFoundError } from '../../domain/errors.ts';

/** Who is acting. Built by requireAuth from the server-side session, never from the request body. */
export interface Actor {
  userId: string;
  role: 'user' | 'admin';
  mfaVerified: boolean;
}

/** Owner-scoped lookups return null for "missing" and "not yours" alike; both become 404. */
export function found<T>(value: T | null | undefined, resource: string): T {
  if (value === null || value === undefined) throw new NotFoundError(resource);
  return value;
}

/**
 * For resources reached through a parent or loaded by a non-owner key
 * (e.g. a comment via its note): check ownership explicitly before use.
 */
export function assertOwnedBy<T extends { ownerId: string }>(resource: T | null | undefined, actor: Actor, name: string): T {
  if (!resource || resource.ownerId !== actor.userId) throw new NotFoundError(name);
  return resource;
}
