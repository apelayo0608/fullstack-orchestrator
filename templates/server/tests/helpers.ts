import type { Express } from 'express';
import request from 'supertest';

export const TEST_ORIGIN = 'http://localhost:5173';

export interface TestUser {
  userId: string;
  /** supertest agent holding a fully MFA-verified session cookie. Send Origin: TEST_ORIGIN on writes. */
  agent: ReturnType<typeof request.agent>;
}

/**
 * Build the real app (real middleware, real repositories) against a disposable
 * Postgres database, e.g. Testcontainers or a per-run schema. Do not mock the
 * repositories in IDOR tests: the owner filter in SQL is what is under test.
 */
export async function buildTestApp(): Promise<Express> {
  throw new Error('buildTestApp: wire the composition root to a test database for this project');
}

/** Create a user, log in, and complete MFA (e.g. TOTP with a known secret). */
export async function loginAs(_app: Express, _name: string): Promise<TestUser> {
  throw new Error('loginAs: implement signup + login + MFA for this project');
}
