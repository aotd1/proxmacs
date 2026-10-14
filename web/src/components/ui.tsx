import { Fragment, useEffect, useRef, useState, type ReactNode } from 'react';
import type { VMState } from '../types';
import { useToast } from './Toasts';

export const Spinner = ({ title }: { title?: string }) => <span className="spinner" title={title} />;

/** `narrow` keeps forms at a readable width on wide screens. */
export function Panel({ title, extra, flush, narrow, children }: {
  title: ReactNode; extra?: ReactNode; flush?: boolean; narrow?: boolean; children: ReactNode;
}) {
  return (
    <section className={`panel${narrow ? ' narrow' : ''}`}>
      <div className="panel-header">
        <h3>{title}</h3>
        {extra && <><div className="spacer" />{extra}</>}
      </div>
      <div className={`panel-body${flush ? ' flush' : ''}`}>{children}</div>
    </section>
  );
}

/** Definition list; falsy rows are skipped. */
export function KV({ rows }: { rows: ([ReactNode, ReactNode] | null | false | undefined)[] }) {
  return (
    <dl className="kv">
      {rows.filter((r): r is [ReactNode, ReactNode] => !!r).map(([k, v], i) => (
        <Fragment key={i}><dt>{k}</dt><dd>{v}</dd></Fragment>
      ))}
    </dl>
  );
}

export function Empty({ children, error }: { children: ReactNode; error?: boolean }) {
  return <div className={`empty${error ? ' error-text' : ''}`}>{children}</div>;
}

export const Loading = ({ what = 'Loading…' }: { what?: string }) => <Empty><Spinner /> {what}</Empty>;

const stateClass = (s: VMState) => (s === 'running' || s === 'stopped' || s === 'missing' || s === 'offline' ? s : 'other');
const badgeClass: Record<string, string> = { running: 'ok', stopped: '', missing: 'err', offline: '' };

export const StateDot = ({ state }: { state: VMState }) => <span className={`dot ${stateClass(state)}`} title={state} />;
export const StateBadge = ({ state }: { state: VMState }) => <span className={`badge ${badgeClass[state] ?? 'warn'}`}>{state || 'unknown'}</span>;
export const Badge = ({ kind = '', title, children }: { kind?: '' | 'ok' | 'err' | 'warn' | 'info'; title?: string; children: ReactNode }) => (
  <span className={`badge ${kind}`} title={title}>{children}</span>
);
export const KindBadge = ({ kind }: { kind: string }) => <Badge kind="info">{kind.toUpperCase()}</Badge>;

export function Meter({ fraction, title }: { fraction: number; title?: string }) {
  const pct = Math.round(Math.min(1, Math.max(0, fraction)) * 100);
  const cls = fraction > 0.9 ? 'err' : fraction > 0.75 ? 'warn' : '';
  return <div className={`meter ${cls}`} title={title ?? `${pct}% used`}><div style={{ width: `${pct}%` }} /></div>;
}

/**
 * Button for async actions: disabled while running, errors are toasted. When disabled with a
 * title, it is wrapped so the tooltip still shows.
 */
export function ActionButton({ onClick, className = '', disabled, title, type = 'button', children }: {
  onClick: () => Promise<unknown> | void;
  className?: string;
  disabled?: boolean;
  title?: string | null;
  type?: 'button' | 'submit';
  children: ReactNode;
}) {
  const [busy, setBusy] = useState(false);
  const { report } = useToast();
  const run = async () => {
    setBusy(true);
    try { await onClick(); } catch (e) { report(e); } finally { setBusy(false); }
  };
  const button = (
    <button type={type} className={`btn ${className}`} disabled={disabled || busy} title={title ?? undefined} onClick={run}>
      {busy && <Spinner />}{children}
    </button>
  );
  return disabled && title ? <span title={title}>{button}</span> : button;
}

export function Field({ label, hint, className = '', children }: { label: ReactNode; hint?: ReactNode; className?: string; children: ReactNode }) {
  return (
    <label className={`field ${className}`}>
      <span>{label}</span>
      {children}
      {hint && <span className="hint">{hint}</span>}
    </label>
  );
}

export function Segmented<T extends string>({ value, options, onChange, name }: {
  value: T;
  options: [T, string, boolean?][];
  onChange: (value: T) => void;
  name: string;
}) {
  return (
    <div className="segmented" role="radiogroup">
      {options.map(([id, label, disabled]) => (
        <label key={id} className={disabled ? 'disabled' : undefined}>
          <input type="radio" name={name} value={id} checked={value === id} disabled={disabled} onChange={() => onChange(id)} />
          {label}
        </label>
      ))}
    </div>
  );
}

export interface MenuItem {
  label: ReactNode;
  onClick: () => Promise<unknown> | void;
  disabled?: boolean;
  title?: string;
  danger?: boolean;
}

/** A button that opens a small menu of actions; errors are toasted. */
export function MenuButton({ label, items, className = '', align = 'left', disabled }: {
  label: ReactNode;
  items: (MenuItem | null | false)[];
  className?: string;
  align?: 'left' | 'right';
  disabled?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const { report } = useToast();
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false); };
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', onDown);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDown);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);
  const run = async (item: MenuItem) => {
    setOpen(false);
    setBusy(true);
    try { await item.onClick(); } catch (e) { report(e); } finally { setBusy(false); }
  };
  return (
    <div className="menu-wrap" ref={ref}>
      <button type="button" className={`btn ${className}`} aria-haspopup="menu" aria-expanded={open} disabled={disabled || busy}
        onClick={() => setOpen(!open)}>
        {busy && <Spinner />}{label}<span className="caret" aria-hidden="true" />
      </button>
      {open && (
        <div className={`menu ${align}`} role="menu">
          {items.filter((i): i is MenuItem => !!i).map((item, i) => (
            <button key={i} type="button" role="menuitem" className={`menu-item${item.danger ? ' danger' : ''}`}
              disabled={item.disabled} title={item.title} onClick={() => run(item)}>
              {item.label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

export function Tags({ tags }: { tags: string[] }) {
  if (!tags.length) return null;
  return <span className="tags">{tags.map((t) => <span key={t} className="tag">{t}</span>)}</span>;
}
