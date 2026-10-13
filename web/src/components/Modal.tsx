import { createContext, useCallback, useContext, useEffect, useRef, useState, type FormEvent, type ReactNode } from 'react';
import { createPortal } from 'react-dom';

// Escape closes only the topmost modal.
const stack: number[] = [];
let nextModalId = 1;

export function Modal({ title, onClose, wide, children }: { title: string; onClose: () => void; wide?: boolean; children: ReactNode }) {
  const dialogRef = useRef<HTMLDivElement>(null);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;

  useEffect(() => {
    const id = nextModalId++;
    stack.push(id);
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && stack[stack.length - 1] === id) {
        e.preventDefault();
        closeRef.current();
      }
    };
    document.addEventListener('keydown', onKey);
    // Focus the first field unless something asked for autofocus.
    const dialog = dialogRef.current;
    if (dialog && !dialog.contains(document.activeElement)) {
      dialog.querySelector<HTMLElement>('input:not([type=hidden]):not(:disabled), select, textarea, .modal-footer .primary')?.focus();
    }
    return () => {
      document.removeEventListener('keydown', onKey);
      stack.splice(stack.indexOf(id), 1);
    };
  }, []);

  return createPortal(
    <div className="modal-backdrop">
      <div ref={dialogRef} className={`modal${wide ? ' wide' : ''}`} role="dialog" aria-modal="true" aria-label={title}>
        <div className="modal-header">
          <h2>{title}</h2>
          <button type="button" className="icon-btn" aria-label="Close" onClick={onClose}>×</button>
        </div>
        {children}
      </div>
    </div>,
    document.body,
  );
}

export interface ConfirmOptions {
  title: string;
  message: ReactNode;
  confirmLabel?: string;
  danger?: boolean;
  /** The user must type this text to enable the confirm button. */
  requireText?: string;
}

type Confirm = (options: ConfirmOptions) => Promise<boolean>;
const ConfirmContext = createContext<Confirm>(async () => false);

export function useConfirm() {
  return useContext(ConfirmContext);
}

export function ConfirmProvider({ children }: { children: ReactNode }) {
  const [request, setRequest] = useState<{ options: ConfirmOptions; resolve: (ok: boolean) => void } | null>(null);
  const confirm = useCallback<Confirm>((options) => new Promise((resolve) => setRequest({ options, resolve })), []);
  const finish = (ok: boolean) => {
    request?.resolve(ok);
    setRequest(null);
  };
  return (
    <ConfirmContext.Provider value={confirm}>
      {children}
      {request && <ConfirmDialog options={request.options} onDone={finish} />}
    </ConfirmContext.Provider>
  );
}

function ConfirmDialog({ options, onDone }: { options: ConfirmOptions; onDone: (ok: boolean) => void }) {
  const { title, message, confirmLabel = 'OK', danger = false, requireText } = options;
  const [typed, setTyped] = useState('');
  const enabled = requireText == null || typed === requireText;
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (enabled) onDone(true);
  };
  return (
    <Modal title={title} onClose={() => onDone(false)}>
      <form onSubmit={submit}>
        <div className="modal-body">
          <p>{message}</p>
          {requireText != null && (
            <label className="field">
              <span>Type <strong>{requireText}</strong> to confirm</span>
              <input type="text" autoComplete="off" spellCheck={false} autoCapitalize="off" autoFocus
                value={typed} onChange={(e) => setTyped(e.target.value)} />
            </label>
          )}
        </div>
        <div className="modal-footer">
          <button type="button" className="btn" onClick={() => onDone(false)}>Cancel</button>
          <button type="submit" className={danger ? 'btn danger solid' : 'btn primary'} disabled={!enabled}
            autoFocus={requireText == null}>
            {confirmLabel}
          </button>
        </div>
      </form>
    </Modal>
  );
}
