export class AuthError extends Error {
  constructor() {
    super('Not authenticated');
  }
}

export class ApiError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

let unauthorized: () => void = () => {};

/** Called whenever the server answers 401 (session expired or logged out elsewhere). */
export function onUnauthorized(handler: () => void) {
  unauthorized = handler;
}

export const enc = encodeURIComponent;

export async function api<T = unknown>(method: string, path: string, body?: unknown): Promise<T> {
  const init: RequestInit = { method, headers: { Accept: 'application/json' }, credentials: 'same-origin', cache: 'no-store' };
  if (method !== 'GET' && method !== 'HEAD') {
    // The server uses this header as CSRF protection: always send it, with a body.
    init.headers = { ...init.headers, 'Content-Type': 'application/json' };
    init.body = JSON.stringify(body ?? {});
  }
  let res: Response;
  try {
    res = await fetch(path, init);
  } catch {
    throw new ApiError('Cannot reach the Proxmacs server', 0);
  }
  if (res.status === 401 && path !== '/api/login') {
    unauthorized();
    throw new AuthError();
  }
  const text = await res.text();
  let data: unknown = null;
  if (text) {
    try { data = JSON.parse(text); } catch { data = text; }
  }
  if (!res.ok) {
    let message = `Request failed (HTTP ${res.status})`;
    if (data && typeof data === 'object' && 'error' in data) message = String((data as { error: unknown }).error);
    else if (typeof data === 'string' && data.length < 300) message = data;
    throw new ApiError(message, res.status);
  }
  return data as T;
}

export function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
