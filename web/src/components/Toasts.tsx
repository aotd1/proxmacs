import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from 'react';
import { AuthError, errorMessage } from '../api';

type Kind = 'error' | 'ok' | 'info';
interface Toast { id: number; message: string; kind: Kind }

interface ToastAPI {
  toast(message: string, kind?: Kind): void;
  /** Toasts an error (ignores AuthError: the login screen takes over). */
  report(e: unknown): void;
}

const ToastContext = createContext<ToastAPI>({ toast: () => {}, report: () => {} });

export function useToast() {
  return useContext(ToastContext);
}

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const nextId = useRef(1);

  const dismiss = useCallback((id: number) => setToasts((list) => list.filter((t) => t.id !== id)), []);

  const toast = useCallback((message: string, kind: Kind = 'error') => {
    const id = nextId.current++;
    setToasts((list) => [...list, { id, message, kind }].slice(-6));
    window.setTimeout(() => dismiss(id), kind === 'error' ? 10_000 : 5_000);
  }, [dismiss]);

  const report = useCallback((e: unknown) => {
    if (e instanceof AuthError) return;
    console.error(e);
    toast(errorMessage(e), 'error');
  }, [toast]);

  const api = useMemo(() => ({ toast, report }), [toast, report]);

  return (
    <ToastContext.Provider value={api}>
      {children}
      <div className="toasts" aria-live="polite">
        {toasts.map((t) => (
          <div key={t.id} className={`toast ${t.kind}`} role={t.kind === 'error' ? 'alert' : 'status'}
            title="Click to dismiss" onClick={() => dismiss(t.id)}>
            {t.message}
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}
