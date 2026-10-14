import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react';
import { api, AuthError, enc, errorMessage } from '../../api';
import { useConfirm } from '../../components/Modal';
import { useToast } from '../../components/Toasts';
import { ActionButton, Badge, Empty, Loading, Panel, Spinner } from '../../components/ui';
import type { Navigate } from '../../components/Shell';
import { fmtDate } from '../../format';
import { useApp } from '../../store';
import type { Backup, BackupPolicy, VM } from '../../types';
import { BackupButton } from './BackupDialog';

export function BackupsView({ vm, navigate }: { vm: VM; navigate: Navigate }) {
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
      <div className="grid2">
        <Panel title="Backup jobs"><JobList vm={vm} navigate={navigate} /></Panel>
        <Panel title="Retention"><RetentionForm vm={vm} /></Panel>
      </div>
      <Panel title="Local backups" flush extra={
        <div className="actions">
          <ActionButton className="small" onClick={load}>Refresh</ActionButton>
          <BackupButton vm={vm} className="primary small" />
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

function JobList({ vm, navigate }: { vm: VM; navigate: Navigate }) {
  const app = useApp();
  const jobs = app.jobs.filter((j) => j.selection === 'all' || (j.selection === 'include') === j.vms.includes(vm.name));
  return (
    <>
      {!jobs.length ? <p className="muted">No backup job includes {vm.name}: it is only backed up when you click Back up now.</p> : (
        <ul className="web-urls">
          {jobs.map((j) => (
            <li key={j.id}>
              <strong>{j.title}</strong> <span className="muted">{j.enabled ? j.schedule : 'disabled'} → {j.targetName ?? 'local backups'}</span>
              {j.lastRun && <div className="small muted">Last run {fmtDate(j.lastRun)}: {j.lastOK ? 'OK' : 'failed'}</div>}
            </li>
          ))}
        </ul>
      )}
      <p className="spaced">
        <button type="button" className="link" onClick={() => navigate({ type: 'host', tab: 'jobs' })}>Manage backup jobs</button>
      </p>
    </>
  );
}

const KEEPS: [keyof BackupPolicy, string][] = [
  ['keep', 'Last'], ['keepDaily', 'Daily'], ['keepWeekly', 'Weekly'], ['keepMonthly', 'Monthly'], ['keepYearly', 'Yearly'],
];

function RetentionForm({ vm }: { vm: VM }) {
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
      toast('Retention saved', 'ok');
    } catch (err) {
      report(err);
    } finally {
      setBusy(false);
    }
  };

  return (
    <form onSubmit={submit}>
      <div className="form-row">
        {KEEPS.map(([key, label]) => (
          <label key={key} className="field">
            <span>{label}</span>
            <input type="number" className="narrow" min={0} max={9999} step={1} required value={policy[key]}
              onChange={(e) => setEdits({ ...edits, [key]: parseInt(e.target.value, 10) || 0 })} />
          </label>
        ))}
        <button type="submit" className="btn primary" disabled={busy || !Object.keys(edits).length}>{busy && <Spinner />}Save</button>
      </div>
      <p className="muted small spaced">
        After each backup, older ones are pruned like on a Proxmox Backup Server: keep the last N, plus the newest backup of
        each of the last N days, weeks, months and years. 0 turns an option off; all 0 keeps everything.
      </p>
    </form>
  );
}
