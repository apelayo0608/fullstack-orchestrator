/** Missing OR owned by someone else. Both map to 404 so ids cannot be probed. */
export class NotFoundError extends Error {
  constructor(resource = 'resource') {
    super(`${resource} not found`);
    this.name = 'NotFoundError';
  }
}

export class UnauthorizedError extends Error {
  constructor() {
    super('authentication required');
    this.name = 'UnauthorizedError';
  }
}

/** Role or step-up failures only (e.g. "mfa_required"). Never use it for ownership. */
export class ForbiddenError extends Error {
  readonly code: string;
  constructor(code = 'forbidden') {
    super(code);
    this.name = 'ForbiddenError';
    this.code = code;
  }
}

export class ValidationError extends Error {
  readonly issues: ReadonlyArray<{ path: string; message: string }>;
  constructor(issues: ReadonlyArray<{ path: string; message: string }>) {
    super('validation failed');
    this.name = 'ValidationError';
    this.issues = issues;
  }
}
