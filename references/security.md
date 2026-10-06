# Security standards

These defaults are non-negotiable unless the user explicitly overrides one. Templates live in `templates/server/src/`.

## 1. AES-256-GCM field encryption (default for sensitive data at rest)

TLS protects data in transit. AES-256-GCM protects sensitive columns at rest, so a database dump, backup or SQL injection does not reveal plaintext.

**Encrypt by default:** PII (email, phone, address, date of birth, government ids), TOTP secrets, third-party OAuth/API tokens, free-text the user would consider private (notes, messages, health or financial data), and anything a brief marks sensitive.
**Hash, never encrypt:** passwords (argon2id), session tokens (SHA-256), OTP and recovery codes (HMAC-SHA256 with `OTP_PEPPER`). These values only ever need comparing, never reading back.
**Leave plaintext:** ids, foreign keys, timestamps, enums, and non-sensitive fields that must be sorted, ranged or full-text searched. If a sensitive field needs equality lookup, add a blind index (§1.4).

### 1.1 Construction (`infrastructure/crypto/aes-gcm.ts`)
- Node `crypto`, `aes-256-gcm`, a **fresh random 12-byte IV per encryption**, 16-byte tag. Never reuse or derive IVs.
- Envelope stored in a `text` column: `v1.<keyId>.<iv>.<tag>.<ciphertext>`, each part base64url.
- **AAD = JSON `["v1", table, column, rowId, ownerId]`.** A ciphertext copied into another row, column or user's record fails authentication. This is the crypto half of IDOR defence.
- Generate `rowId` in the application (UUIDv7) **before** INSERT so it is available for AAD.
- Decryption failures throw a generic `DecryptionError` (no detail about which part failed), surface as 500, and are logged as security events.
- Encryption and decryption happen **only in infrastructure repositories**. Domain and application code see plaintext; controllers never touch envelopes.

### 1.2 Keys (`infrastructure/crypto/key-ring.ts`)
- `DATA_KEYS` = JSON `{keyId: base64(32 random bytes)}`, `DATA_ACTIVE_KEY` = id used for new writes. Key ids match `[A-Za-z0-9_-]{1,32}`.
- Keys come from a secrets manager or KMS in production. `.env` is for local dev only, is git-ignored, and `.env.example` holds placeholders.
- **Rotation:** add a new key → switch `DATA_ACTIVE_KEY` → batch job re-encrypts rows where `needsRotation(envelope)` → remove the old key after the job verifies zero remaining rows. With random 96-bit IVs, stay far below 2^32 encryptions per key.
- Separate keys per purpose: `DATA_KEYS` (encryption), `BLIND_INDEX_KEY` (HMAC lookups), `OTP_PEPPER` (OTP and recovery code hashes), session signing if any. Never reuse one key for two purposes.

### 1.3 Logging and errors
Never log plaintext of encrypted fields, keys, envelopes, OTPs, passwords, session tokens or full request bodies on auth routes. Error responses carry codes, not internals.

### 1.4 Blind index (`infrastructure/crypto/blind-index.ts`)
`HMAC-SHA256(BLIND_INDEX_KEY, purpose || 0x00 || normalized value)` in a `<column>_bidx` column, with a unique index when the column is unique (e.g. `users.email_bidx`). Normalize first (`normalizeEmail`). Blind indexes allow equality matching only.

## 2. IDOR (Insecure Direct Object Reference)

Every user-owned resource is reachable only by its owner (or an explicitly authorized role), whatever id a client sends.

1. **Owner-scoped repositories.** Methods take the owner and filter in SQL: `findForOwner(id, ownerId)`, `updateForOwner`, `deleteForOwner`, `listForOwner`, each with `WHERE id = $1 AND owner_id = $2`. No unscoped `findById` is reachable from an HTTP handler. Admin access uses a separate repository and use case with its own role check.
2. **Actor from the session only.** `requireAuth` builds `req.actor` from the server-side session. `ownerId`, `userId`, `tenantId`, `role` and `isAdmin` are **never** read from body, query, params or headers.
3. **Strict input schemas.** zod `z.strictObject` rejects unknown keys (mass assignment). DTOs list allowed fields explicitly. Responses map entities to explicit DTOs; never `res.json(row)`.
4. **404 for foreign resources**, identical to "does not exist", so ids cannot be probed. 403 is reserved for role or step-up failures (`mfa_required`).
5. **Nested resources:** verify the parent belongs to the actor (`/notes/:noteId/comments/:id` checks both note ownership and that the comment belongs to that note).
6. **Bulk and batch operations** scope every id: `WHERE id = ANY($1) AND owner_id = $2`. Compare affected count to requested count.
7. **Indirect references:** file keys, signed URLs, export jobs, websocket rooms, background job payloads and webhooks carry or check the owner too. Signed URLs are short-lived and scoped to one object.
8. **Malformed ids** (non-UUID) → 404, never a 500 from Postgres.
9. **Identifiers:** UUIDv7, not sequential integers. This is defence in depth only; it does not replace the checks above.
10. **Optional RLS:** Postgres row-level security with `set_config('app.user_id', $1, true)` per transaction, as a second wall (see migration template).
11. **Tests:** every resource endpoint has a cross-user suite (`templates/server/tests/idor.test.ts`): read, list, update, delete, body-supplied owner, malformed id, no session.

## 3. Authentication and MFA (email OTP + TOTP)

### 3.1 Flow
1. `POST /api/auth/login {email, password}`: look up by `email_bidx`, verify argon2id (constant-time; run a dummy verify for unknown users). Rate-limit per IP and per account. On success create a **`mfa_pending` session** (`mfa_verified = false`, expiry ≤ 10 min) and return `{ methods }`.
2. **Every login requires a second factor:** TOTP when enrolled, email OTP otherwise (email is always available).
3. `POST /api/auth/mfa/verify {method, code}`: verify, then **rotate the session token** (new token, delete the pending one) with `mfa_verified = true` and a normal expiry.
4. All app routes use `requireAuth` + `requireMfa`. Only `/auth/login`, `/auth/mfa/*` and `/auth/logout` accept a pending session.

### 3.2 TOTP (`application/mfa/totp.service.ts`, `infrastructure/crypto/totp.ts`)
- RFC 6238, SHA-1, 6 digits, 30 s, ±1 step window, 160-bit secret.
- Secret encrypted with AES-256-GCM (AAD `mfa_totp/secret_enc/userId/userId`). It is shown only once at enrolment as an `otpauth://` URI / QR code.
- Enrolment: requires recent re-authentication → unconfirmed secret → user submits a valid code → confirmed → issue 10 recovery codes (high-entropy, HMAC-hashed, shown once).
- **Replay guard:** atomically store the last accepted step; reject any step ≤ it.
- Disabling TOTP or regenerating recovery codes requires re-authentication plus a current factor, and sends an email notice.

### 3.3 Email OTP (`application/mfa/email-otp.service.ts`)
- 6 digits from `crypto.randomInt`, stored as HMAC-SHA256 with `OTP_PEPPER`, 10-minute TTL, single use (atomic consume), max 5 attempts (increment before compare), issuing a new code invalidates older ones.
- Send rate limit: e.g. 3 per 15 min per user and per IP. The address comes from the pending session's user, never from the request.
- Email body contains the code and no clickable login link.

### 3.4 Sessions and cookies
- Opaque 256-bit random token in cookie `__Host-sid`: `HttpOnly; Secure; SameSite=Lax; Path=/`, no `Domain`. The DB stores `sha256(token)` only.
- Rotate the token on login, MFA success and privilege change. Logout deletes the server row. Idle and absolute timeouts are enforced server-side.
- No JWTs in localStorage. No tokens in Zustand or any JS-readable storage.

### 3.5 Passwords
argon2id (`argon2` package, library defaults or stronger), minimum 12 characters, check against a breached-password list if available, and no composition rules beyond length.

## 4. Baseline API hardening
- `helmet()`, `app.disable('x-powered-by')`, `express.json({ limit: '100kb' })`.
- `express-rate-limit` on `/api`, plus much stricter limits on auth and OTP routes. Set `trust proxy` correctly in production.
- CSRF: SameSite cookies **plus** `sameOriginWrites` (Origin / Sec-Fetch-Site check on unsafe methods).
- CORS: none in dev (the Vite proxy makes requests same-origin). In production prefer same-origin hosting; otherwise use an explicit origin allowlist with `credentials: true` and never `*`.
- SQL only through parameterized queries (`$1…`). No string-built SQL, including `ORDER BY`. Map sort fields through an allowlist.
- Validate every input with zod at the HTTP edge. Validate env config at startup and fail fast.
- Central error handler: domain errors → status codes, everything else → `500 {error:'internal_error'}`. No stack traces or SQL in responses.
- File uploads: size limits, type sniffing, random storage keys, never served from the app origin without `Content-Disposition`.
- Dependencies: lockfile committed, `npm audit` clean of high and critical issues.

## 5. Frontend
- No secrets in client code or `VITE_*` env vars (they are public).
- Render user content as text. Do not use `dangerouslySetInnerHTML`; if HTML is unavoidable, sanitize with DOMPurify.
- Every authorization decision happens on the server; client checks are UX only.
- Clear the TanStack Query cache on logout and on 401.

## Reviewer checklist
- [ ] **IDOR / ownership:** every query on user-owned data filters by the actor's id inside SQL; no unscoped lookup is reachable from a handler; nested and bulk paths are scoped; foreign resources return 404.
- [ ] **Actor source:** owner, user or role ids come only from `req.actor`; no body, query or param can set or override them; zod schemas are strict.
- [ ] **Cross-user tests:** each new or changed resource endpoint has read, list, update, delete, body-owner, malformed-id and no-session tests.
- [ ] **Encryption:** sensitive fields use `FieldEncryptor` with AAD `[table, column, rowId, ownerId]` matching the real row; a random IV each time; no plaintext copies, logs or responses beyond the intended DTO; passwords, OTPs and tokens are hashed, not encrypted.
- [ ] **Keys and secrets:** no keys, peppers, passwords or tokens in code, tests, fixtures, logs or `VITE_*` vars; new env vars appear in `.env.example` with placeholders and in startup validation.
- [ ] **MFA and session:** protected routes require `requireAuth` + `requireMfa`; TOTP replay guard and ±1 window; email OTP TTL, attempts, single use and rate limits; session rotation on login and MFA success; cookie flags correct.
- [ ] **Injection and validation:** parameterized SQL only, including dynamic sort/filter; all inputs validated; output encoded; no `dangerouslySetInnerHTML` on user data.
- [ ] **CSRF, CORS and headers:** unsafe methods pass `sameOriginWrites`; no wildcard CORS with credentials; helmet active; rate limits on auth routes.
- [ ] **Error handling:** domain errors are mapped correctly; no stack traces or internals leak; async errors reach the handler.
- [ ] **Correctness:** edge cases (empty, null, concurrent updates, pagination bounds, time zones), transactions where multiple writes must be atomic, no unhandled promise.
- [ ] **Architecture:** dependency rule holds (domain imports nothing outward; application depends only on ports); no business logic in routes or React components; server state in TanStack Query, not Zustand.
- [ ] **Frontend behaviour:** loading, error and empty states; query invalidation after mutations; animations respect `prefers-reduced-motion`; accessible labels and focus handling on forms and dialogs.
- [ ] **Tests and build:** the tests the developer reports actually cover the change; nothing skipped or `.only`; types are not silenced with `any` or `@ts-ignore`.
