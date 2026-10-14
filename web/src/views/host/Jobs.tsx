import { useEffect, useState, type FormEvent } from 'react';
import { api, enc } from '../../api';
import { Modal, useConfirm } from '../../components/Modal';
import type { Navigate } from '../../components/Shell';
import { useToast } from '../../components/Toasts';
import { ActionButton, Badge, Empty, Field, Panel, Segmented, Spinner } from '../../components/ui';
import { fmtDate, pad2 } from '../../format';
import { useApp } from '../../store';
import type { BackupJob, NotifyWhen } from '../../types';

const DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

export function JobsView({ navigate }: { navigate: Navigate }) {
  const app = useApp();
  const confirm = useConfirm();
  const { toast } = useToast();
  const [editing, setEditing] = useState<BackupJob | 'new' | null>(null);
  const { reloadJobs } = app;
  useEffect(() => { void reloadJobs(); }, [reloadJobs]);

  const selection = (j: BackupJob) => j.selection === 'all' ? 'All VMs'
    : j.selection === 'include' ? j.vms.join(', ') : `All except ${j.vms.join(', ')}`;
  const run = async (j: BackupJob) => {
    await app.startTask('POST', `/api/jobs/${enc(j.id)}/run`, {}, j.title);
    window.setTimeout(() => void reloadJobs(), 500);
  };
  const remove = async (j: BackupJob) => {
    const ok = await confirm({ title: 'Delete backup job', message: `Delete “${j.title}”? Existing backups are kept.`, confirmLabel: 'Delete', danger: true });
    if (!ok) return;
    await api('DELETE', `/api/jobs/${enc(j.id)}`, {});
    toast('Backup job deleted', 'ok');
    await reloadJobs();
  };
  const toggle = async (j: BackupJob, enabled: boolean) => {
    await api('PUT', `/api/jobs/${enc(j.id)}`, { enabled });
    await reloadJobs();
  };

  return (
    <>
      <Panel title="Backup jobs" flush extra={<button type="button" className="btn primary small" onClick={() => setEditing('new')}>Add job</button>}>
        {!app.jobs.length ? <Empty>No backup jobs. Add one to back up VMs on a schedule.</Empty> : (
          <table className="table">
            <thead><tr><th>On</th><th>Job</th><th className="wide-only">VMs</th><th className="wide-only">Next run</th><th>Last run</th><th /></tr></thead>
            <tbody>
              {app.jobs.map((j) => (
                <tr key={j.id}>
                  <td><input type="checkbox" className="switch" checked={j.enabled} aria-label={`Enable ${j.title}`}
                    onChange={(e) => void toggle(j, e.target.checked)} /></td>
                  <td>
                    <strong>{j.title}</strong>
                    <div className="small muted">
                      {j.schedule} → {j.targetName ?? (j.target ? <span className="error-text">missing target</span> : 'local backups')}
                      {j.notify !== 'never' && ` · notify ${j.notify === 'always' ? 'always' : 'on failure'}`}
                    </div>
                  </td>
                  <td className="wide-only wrap">{selection(j)}</td>
                  <td className="wide-only nowrap">{j.nextRun ? fmtDate(j.nextRun) : '—'}</td>
                  <td>
                    {j.running ? <span className="task-status"><Spinner />running</span>
                      : !j.lastRun ? <span className="muted">never</span>
                        : <>
                          <Badge kind={j.lastOK ? 'ok' : 'err'} title={j.lastMessage ?? undefined}>{j.lastOK ? 'OK' : 'Failed'}</Badge>
                          <div className="small muted nowrap">{fmtDate(j.lastRun)}</div>
                        </>}
                  </td>
                  <td className="actions-cell">
                    <div className="actions">
                      <ActionButton className="small" disabled={j.running} onClick={() => run(j)}>Run now</ActionButton>
                      <button type="button" className="btn small" onClick={() => setEditing(j)}>Edit</button>
                      <ActionButton className="small danger" onClick={() => remove(j)}>Delete</ActionButton>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Panel>
      <p className="muted small prose">
        A job backs up its VMs one after another. How many backups each VM keeps is set on the VM’s Backups tab; VMs set to
        push offsite automatically are pushed after their backup. A run missed while this Mac slept or Proxmacs wasn’t running
        is made up within 12 hours. Get notified through{' '}
        <button type="button" className="link" onClick={() => navigate({ type: 'host', tab: 'notifications' })}>notification webhooks</button>.
      </p>
      {editing && <JobDialog job={editing === 'new' ? null : editing} onClose={() => setEditing(null)} />}
    </>
  );
}

function JobDialog({ job, onClose }: { job: BackupJob | null; onClose: () => void }) {
  const app = useApp();
  const { toast, report } = useToast();
  const [comment, setComment] = useState(job?.comment ?? '');
  const [enabled, setEnabled] = useState(job?.enabled ?? true);
  const [time, setTime] = useState(`${pad2(job?.hour ?? 3)}:${pad2(job?.minute ?? 0)}`);
  const [days, setDays] = useState<Set<number>>(new Set(job?.days ?? []));
  const [selection, setSelection] = useState<BackupJob['selection']>(job?.selection ?? 'all');
  const [vms, setVMs] = useState<Set<string>>(new Set(job?.vms ?? []));
  const [notify, setNotify] = useState<NotifyWhen>(job?.notify ?? 'failure');
  const [target, setTarget] = useState(job?.target ?? 'local');
  const [busy, setBusy] = useState(false);
  const names = [...new Set([...app.vms.map((v) => v.name), ...(job?.vms ?? [])])].sort();
  const toggle = <T,>(set: Set<T>, value: T, on: boolean) => {
    const next = new Set(set);
    if (on) next.add(value); else next.delete(value);
    return next;
  };

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    const [hour, minute] = time.split(':').map((n) => parseInt(n, 10));
    const body = {
      comment, enabled, hour, minute, days: [...days].sort(), selection, vms: selection === 'all' ? [] : [...vms], notify,
      target: target === 'local' ? null : target,
    };
    setBusy(true);
    try {
      await api(job ? 'PUT' : 'POST', job ? `/api/jobs/${enc(job.id)}` : '/api/jobs', body);
      toast(job ? 'Backup job saved' : 'Backup job added', 'ok');
      await app.reloadJobs();
      onClose();
    } catch (err) {
      report(err);
      setBusy(false);
    }
  };

  return (
    <Modal title={job ? `Edit ${job.title}` : 'Add backup job'} onClose={onClose}>
      <form onSubmit={submit}>
        <div className="modal-body stack">
          <div className="form-grid">
            <Field label="Name" hint="Optional"><input type="text" maxLength={200} placeholder="Nightly" value={comment}
              onChange={(e) => setComment(e.target.value)} /></Field>
            <Field label="Time"><input type="time" required value={time} onChange={(e) => setTime(e.target.value)} /></Field>
          </div>
          <div className="field">
            <span>Days</span>
            <div className="days">
              {DAYS.map((d, i) => (
                <label key={d} className="check">
                  <input type="checkbox" checked={days.has(i + 1)} onChange={(e) => setDays(toggle(days, i + 1, e.target.checked))} />{d}
                </label>
              ))}
            </div>
            <span className="hint">{days.size === 0 || days.size === 7 ? 'Every day.' : 'Only on the checked days.'}</span>
          </div>
          <div className="field">
            <span>VMs</span>
            <Segmented name="selection" value={selection} onChange={setSelection}
              options={[['all', 'All'], ['include', 'Selected'], ['exclude', 'All except']]} />
            {selection !== 'all' && (
              <div className="vm-checks">
                {names.map((n) => (
                  <label key={n} className="check">
                    <input type="checkbox" checked={vms.has(n)} onChange={(e) => setVMs(toggle(vms, n, e.target.checked))} />{n}
                  </label>
                ))}
              </div>
            )}
            {selection === 'all' && <span className="hint">Includes VMs created later.</span>}
          </div>
          <Field label="Destination" hint={target === 'local'
            ? 'Instant APFS clones in local backups; VMs set to push offsite automatically are pushed afterwards.'
            : `Straight to ${app.target(target)?.name ?? 'the target'}, without local backups; keeps the target’s newest ${app.target(target)?.keep ?? ''} per VM.`}>
            <select value={target} onChange={(e) => setTarget(e.target.value)}>
              <option value="local">Local backups</option>
              {app.targets.map((t) => <option key={t.id} value={t.id}>{t.name} ({t.kind.toUpperCase()})</option>)}
              {target !== 'local' && !app.target(target) && <option value={target}>missing target</option>}
            </select>
          </Field>
          <div className="form-grid">
            <Field label="Notify" hint="Through every enabled notification webhook">
              <select value={notify} onChange={(e) => setNotify(e.target.value as NotifyWhen)}>
                <option value="failure">On failure</option>
                <option value="always">Always</option>
                <option value="never">Never</option>
              </select>
            </Field>
            <label className="check tall" style={{ alignSelf: 'end' }}>
              <input type="checkbox" className="switch" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />Enabled
            </label>
          </div>
        </div>
        <div className="modal-footer">
          <button type="button" className="btn" onClick={onClose}>Cancel</button>
          <button type="submit" className="btn primary" disabled={busy || (selection === 'include' && !vms.size)}>{busy && <Spinner />}{job ? 'Save' : 'Add job'}</button>
        </div>
      </form>
    </Modal>
  );
}
