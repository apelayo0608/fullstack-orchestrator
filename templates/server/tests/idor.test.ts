import type { Express } from 'express';
import request from 'supertest';
import { beforeAll, describe, expect, it } from 'vitest';
import { buildTestApp, loginAs, TEST_ORIGIN, type TestUser } from './helpers.ts';

// Copy this suite for EVERY user-owned resource (and nested resources via their parent).
// Required cases: read, list, update, delete, body-supplied owner, malformed id, no session.

describe('notes: cross-user access (IDOR)', () => {
  let app: Express;
  let alice: TestUser;
  let bob: TestUser;
  let aliceNoteId: string;

  beforeAll(async () => {
    app = await buildTestApp();
    alice = await loginAs(app, 'alice');
    bob = await loginAs(app, 'bob');
    const res = await alice.agent.post('/api/notes').set('Origin', TEST_ORIGIN).send({ title: 'mine', body: 'secret' }).expect(201);
    aliceNoteId = res.body.id;
  });

  it("bob cannot read alice's note (404, not 403)", async () => {
    await bob.agent.get(`/api/notes/${aliceNoteId}`).expect(404);
  });

  it("bob's list never contains alice's notes", async () => {
    const res = await bob.agent.get('/api/notes').expect(200);
    expect(res.body.map((n: { id: string }) => n.id)).not.toContain(aliceNoteId);
  });

  it("bob cannot update alice's note, and it stays unchanged", async () => {
    await bob.agent.patch(`/api/notes/${aliceNoteId}`).set('Origin', TEST_ORIGIN).send({ title: 'pwned', body: 'pwned' }).expect(404);
    const res = await alice.agent.get(`/api/notes/${aliceNoteId}`).expect(200);
    expect(res.body).toMatchObject({ title: 'mine', body: 'secret' });
  });

  it("bob cannot delete alice's note", async () => {
    await bob.agent.delete(`/api/notes/${aliceNoteId}`).set('Origin', TEST_ORIGIN).expect(404);
    await alice.agent.get(`/api/notes/${aliceNoteId}`).expect(200);
  });

  it('rejects owner fields supplied in the body', async () => {
    await bob.agent
      .post('/api/notes')
      .set('Origin', TEST_ORIGIN)
      .send({ title: 't', body: 'b', ownerId: alice.userId })
      .expect(400);
  });

  it('treats a malformed id as not found, not a server error', async () => {
    await alice.agent.get('/api/notes/not-a-uuid').expect(404);
  });

  it('requires a session', async () => {
    await request(app).get(`/api/notes/${aliceNoteId}`).expect(401);
  });

  it('rejects writes from a foreign origin (CSRF)', async () => {
    await alice.agent.post('/api/notes').set('Origin', 'https://evil.example').send({ title: 't', body: 'b' }).expect(403);
  });
});
