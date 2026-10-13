import { useCallback, useEffect, useRef, useState } from 'react';

/**
 * Calls `fn` now and then every `ms` while the page is visible. Runs never overlap; `now()`
 * triggers an immediate run (queued if one is in flight).
 */
export function usePoller(fn: () => Promise<void>, ms: number, enabled = true): () => void {
  const fnRef = useRef(fn);
  fnRef.current = fn;
  const nowRef = useRef<() => void>(() => {});

  useEffect(() => {
    if (!enabled) return;
    let timer: number | undefined;
    let stopped = false, running = false, again = false;
    const tick = async () => {
      window.clearTimeout(timer);
      timer = undefined;
      if (stopped) return;
      if (running) { again = true; return; }
      if (document.visibilityState === 'visible') {
        running = true;
        try { await fnRef.current(); } catch { /* the callback reports its own errors */ }
        running = false;
        if (again && !stopped) { again = false; void tick(); return; }
      }
      if (!stopped) timer = window.setTimeout(tick, ms);
    };
    const onVisible = () => { if (document.visibilityState === 'visible') void tick(); };
    nowRef.current = () => void tick();
    document.addEventListener('visibilitychange', onVisible);
    void tick();
    return () => {
      stopped = true;
      window.clearTimeout(timer);
      document.removeEventListener('visibilitychange', onVisible);
      nowRef.current = () => {};
    };
  }, [ms, enabled]);

  return useCallback(() => nowRef.current(), []);
}

/** Phone-sized layout; keep in sync with the 760px breakpoint in app.css. */
export const NARROW = '(max-width: 760px)';

export function useLocalStorage<T>(key: string, initial: T): [T, (value: T) => void] {
  const [value, setValue] = useState<T>(() => {
    try {
      const raw = localStorage.getItem(key);
      return raw == null ? initial : (JSON.parse(raw) as T);
    } catch {
      return initial;
    }
  });
  const set = useCallback((next: T) => {
    setValue(next);
    try { localStorage.setItem(key, JSON.stringify(next)); } catch { /* storage unavailable */ }
  }, [key]);
  return [value, set];
}

export type Route =
  | { type: 'host'; tab: string }
  | { type: 'vm'; name: string; tab: string };

function parseHash(hash: string): Route {
  const parts = hash.replace(/^#\/?/, '').split('/');
  if (parts[0] === 'vm' && parts[1]) {
    try {
      return { type: 'vm', name: decodeURIComponent(parts[1]), tab: parts[2] || 'summary' };
    } catch { /* fall through */ }
  }
  return { type: 'host', tab: parts[0] === 'host' && parts[1] ? parts[1] : 'summary' };
}

export function routeHash(route: Route): string {
  return route.type === 'vm' ? `#/vm/${encodeURIComponent(route.name)}/${route.tab}` : `#/host/${route.tab}`;
}

/** `#/host/<tab>` and `#/vm/<name>/<tab>`. */
export function useHashRoute(): [Route, (route: Route) => void] {
  const [route, setRoute] = useState(() => parseHash(location.hash));
  useEffect(() => {
    const onChange = () => setRoute(parseHash(location.hash));
    window.addEventListener('hashchange', onChange);
    return () => window.removeEventListener('hashchange', onChange);
  }, []);
  const navigate = useCallback((next: Route) => {
    const hash = routeHash(next);
    if (location.hash !== hash) history.pushState(null, '', hash);
    setRoute(next);
  }, []);
  return [route, navigate];
}

export async function copyText(text: string): Promise<boolean> {
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch { /* fall back below */ }
  const ta = document.createElement('textarea');
  ta.value = text;
  ta.style.cssText = 'position:fixed;left:-9999px;top:0';
  document.body.append(ta);
  ta.select();
  let ok = false;
  try { ok = document.execCommand('copy'); } catch { ok = false; }
  ta.remove();
  return ok;
}
