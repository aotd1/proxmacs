import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react';
import { api, AuthError, enc, errorMessage } from '../../api';
import { useConfirm } from '../../components/Modal';
import { useToast } from '../../components/Toasts';
import { ActionButton, Badge, Empty, Loading, Panel, Spinner } from '../../components/ui';
import { fmtDate, pad2 } from '../../format';
import { useApp } from '../../store';
import type { Backup, BackupPolicy, VM } from '../../types';
import { vmBackup } from './actions';

export function BackupsView({ vm }: { vm: VM }) {
  const app = useApp();
  const confirm = useConfirm();
  const { toast, report } = useToast();
  const [backups, setBackups] = useState<Backup[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const seq = useRef(0);
  const name = vm.name;

  const load = useCallback(async () => {
    const my = ++seq.current;
    try {
      const list = await api<Backup[]>('GET', `/api/vms/${enc(name)}/backups`);
      if (my !== seq.current) return;
      setBackups(list);
      setError(null);
    } catch (e) {
      if (e instanceof AuthError || my !== seq.current) return;
      setError(errorMessage(e));
    }
  }, [name]);
  // Reload whenever one of this VM's tasks (backup, restore, pull…) finishes.
  const epoch = app.taskEpoch[name] ?? 0;
  useEffect(() => { void load(); }, [load, epoch]);

  const restore = async (b: Backup) => {
    const ok = await confirm({
      title: `Restore ${name}`,
      message: `Restore “${name}” from the backup of ${fmtDate(b.date)}? The VM’s current disk will be replaced; changes since then are lost.`,
      confirmLabel: 'Restore', danger: true,
    });
    if (ok) await app.startTask('POST', `/api/vms/${enc(name)}/backups/${enc(b.id)}/restore`, {}, `Restore ${name}`);
  };

  const remove = async (b: Backup) => {
    const ok = await confirm({
      title: 'Delete backup',
      message: `Delete the local backup of “${name}” from ${fmtDate(b.date)}? This cannot be undone.`,
      confirmLabel: 'Delete', danger: true,
    });
    if (!ok) return;
    await api('DELETE', `/api/vms/${enc(name)}/backups/${enc(b.id)}`, {});
    toast('Backup deleted', 'ok');
    await load();
  };

  const push = async (b: Backup, targetId: string) => {
    const target = app.target(targetId);
    try {
      await app.startTask('POST', `/api/vms/${enc(name)}/backups/${enc(b.id)}/push`, { target: targetId },
        `Push ${name} backup to ${target?.name ?? 'target'}`);
    } catch (e) {
      report(e);
    }
  };

  const running = vm.state === 'running';
  return (
    <>
      <Panel title="Schedule"><ScheduleForm vm={vm} /></Panel>
      <Panel title="Local backups" flush extra={
        <div className="actions">
          <ActionButton className="small" onClick={load}>Refresh</ActionButton>
          <ActionButton className="primary small" disabled={vm.state === 'missing' || vm.state === 'offline'} onClick={() => vmBackup(app.startTask, vm)}>Back up now</ActionButton>
        </div>
      }>
        {error ? <Empty error>{error}</Empty> : !backups ? <Loading what="Loading backups…" /> : !backups.length ? <Empty>No local backups yet.</Empty> : (
          <table className="table">
            <thead><tr><th>Date</th><th>Type</th><th>Source</th><th /></tr></thead>
            <tbody>
              {backups.map((b) => (
                <tr key={b.id}>
                  <td className="nowrap" title={b.id}>{fmtDate(b.date)}</td>
                  <td>{b.consistent
                    ? <Badge kind="ok" title="Taken while the VM was stopped or quiesced">consistent</Badge>
                    : <Badge kind="warn" title="Taken while the VM was running">crash-consistent</Badge>}</td>
                  <td className="muted wrap">{b.source || '—'}</td>
                  <td className="actions-cell">
                    <div className="actions">
                      <ActionButton className="small" disabled={running} title={running ? 'Stop the VM first' : null} onClick={() => restore(b)}>Restore</ActionButton>
                      <select className="small" value="" disabled={!app.targets.length}
                        title={app.targets.length ? 'Copy this backup to an offsite target' : 'No backup targets configured'}
                        onChange={(e) => { if (e.target.value) void push(b, e.target.value); }}>
                        <option value="">{app.targets.length ? 'Push to…' : 'Push to… (no targets)'}</option>
                        {app.targets.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                      </select>
                      <ActionButton className="small danger" onClick={() => remove(b)}>Delete</ActionButton>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Panel>
    </>
  );
}

function ScheduleForm({ vm }: { vm: VM }) {
  const app = useApp();
  const { toast, report } = useToast();
  const [edits, setEdits] = useState<Partial<BackupPolicy>>({});
  const [busy, setBusy] = useState(false);
  const policy = { ...vm.backup, ...edits };

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    try {
      app.updateVM(await api<VM>('PATCH', `/api/vms/${enc(vm.name)}`, { backup: policy }));
      setEdits({});
      toast('Backup schedule saved', 'ok');
    } catch (err) {
      report(err);
    } finally {
      setBusy(false);
    }
  };

  return (
    <form onSubmit={submit}>
      <div className="form-row">
        <label className="check tall">
          <input type="checkbox" className="switch" checked={policy.daily} onChange={(e) => setEdits({ ...edits, daily: e.target.checked })} />
          Daily backup
        </label>
        <label className="field">
          <span>At</span>
          <select value={policy.hour} disabled={!policy.daily} onChange={(e) => setEdits({ ...edits, hour: parseInt(e.target.value, 10) })}>
            {Array.from({ length: 24 }, (_, i) => <option key={i} value={i}>{pad2(i)}:00</option>)}
          </select>
        </label>
        <label className="field">
          <span>Keep</span>
          <input type="number" className="narrow" min={1} max={999} step={1} required value={policy.keep}
            onChange={(e) => setEdits({ ...edits, keep: parseInt(e.target.value, 10) || 1 })} />
        </label>
        <button type="submit" className="btn primary" disabled={busy || !Object.keys(edits).length}>{busy && <Spinner />}Save</button>
      </div>
      <p className="muted small spaced">Keep = number of local backups retained; older ones are pruned automatically.</p>
    </form>
  );
}
