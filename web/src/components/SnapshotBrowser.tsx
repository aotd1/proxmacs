import { useCallback, useEffect, useImperativeHandle, useRef, useState, type Ref } from 'react';
import { api, AuthError, enc, errorMessage } from '../api';
import { fmtDate } from '../format';
import { useApp } from '../store';
import type { Snapshot } from '../types';
import { ActionButton, Empty, Spinner } from './ui';

export interface SnapshotBrowserHandle {
  load(): Promise<void>;
}

type State =
  | { status: 'idle' }
  | { status: 'loading'; items: Snapshot[] }
  | { status: 'ok'; items: Snapshot[] }
  | { status: 'error'; message: string };

/** Remote snapshots of one VM name on one target (Offsite tab and host recovery). */
export function SnapshotBrowser({ targetId, vm, autoLoad, ref }: { targetId: string; vm: string; autoLoad?: boolean; ref?: Ref<SnapshotBrowserHandle> }) {
  const app = useApp();
  const [state, setState] = useState<State>({ status: 'idle' });
  const seq = useRef(0);

  const load = useCallback(async () => {
    const my = ++seq.current;
    setState((s) => ({ status: 'loading', items: s.status === 'ok' || s.status === 'loading' ? s.items : [] }));
    try {
      const items = await api<Snapshot[]>('GET', `/api/targets/${enc(targetId)}/snapshots?vm=${enc(vm)}`);
      if (my !== seq.current) return;
      setState({ status: 'ok', items: [...items].sort((a, b) => b.time.localeCompare(a.time)) });
    } catch (e) {
      if (e instanceof AuthError || my !== seq.current) return;
      setState({ status: 'error', message: errorMessage(e) });
    }
  }, [targetId, vm]);

  useImperativeHandle(ref, () => ({ load }), [load]);
  useEffect(() => { if (autoLoad) void load(); }, [autoLoad, load]);

  const pull = (s: Snapshot) => {
    const target = app.target(targetId);
    return app.startTask('POST', `/api/targets/${enc(targetId)}/pull`, { vm: s.vm || vm, id: s.id },
      `Pull ${s.vm || vm} from ${target?.name ?? 'target'}`);
  };

  const verify = (s: Snapshot) => {
    const target = app.target(targetId);
    return app.startTask('POST', `/api/targets/${enc(targetId)}/verify`, { vm: s.vm || vm, id: s.id },
      `Verify ${s.vm || vm} on ${target?.name ?? 'target'}`);
  };

  if (state.status === 'idle') return null;
  if (state.status === 'error') return <Empty error>{state.message}</Empty>;
  if (state.status === 'loading' && !state.items.length) return <Empty><Spinner /> Loading snapshots…</Empty>;
  if (!state.items.length) return <Empty>No remote snapshots for “{vm}”.</Empty>;
  return (
    <table className="table">
      <thead><tr><th>Time</th><th>Snapshot</th><th /></tr></thead>
      <tbody>
        {state.items.map((s) => (
          <tr key={s.id}>
            <td className="nowrap">{fmtDate(s.time)}</td>
            <td className="wrap mono muted">{s.id}</td>
            <td className="actions-cell">
              <div className="actions">
                <ActionButton className="small" title="Read the snapshot back and check every chunk" onClick={() => verify(s)}>Verify</ActionButton>
                <ActionButton className="small" title="Copy this snapshot into local backups" onClick={() => pull(s)}>Pull</ActionButton>
              </div>
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
