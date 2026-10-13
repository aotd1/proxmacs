import { useEffect, useState, type FormEvent } from 'react';
import { api, AuthError, enc, errorMessage } from '../../api';
import { useConfirm } from '../../components/Modal';
import { SnapshotBrowser } from '../../components/SnapshotBrowser';
import { useToast } from '../../components/Toasts';
import { ActionButton, Badge, Empty, Field, KindBadge, Panel, Segmented, Spinner } from '../../components/ui';
import { useApp } from '../../store';
import type { Target } from '../../types';

type TestResult = { state: 'testing' } | { state: 'ok' | 'fail'; message: string };

export function TargetsView() {
  const app = useApp();
  const confirm = useConfirm();
  const { toast } = useToast();
  const [results, setResults] = useState<Record<string, TestResult>>({});

  const { reloadTargets } = app;
  useEffect(() => { void reloadTargets(); }, [reloadTargets]);

  const test = async (t: Target) => {
    setResults((r) => ({ ...r, [t.id]: { state: 'testing' } }));
    let result: TestResult;
    try {
      const r = await api<{ ok: boolean; message: string }>('POST', `/api/targets/${enc(t.id)}/test`, {});
      result = { state: r.ok ? 'ok' : 'fail', message: r.message };
    } catch (e) {
      if (e instanceof AuthError) return;
      result = { state: 'fail', message: errorMessage(e) };
    }
    setResults((r) => ({ ...r, [t.id]: result }));
  };

  const remove = async (t: Target) => {
    const ok = await confirm({
      title: 'Delete backup target',
      message: `Delete backup target “${t.name}”? Snapshots already stored on it are not removed, but VMs will stop pushing to it.`,
      confirmLabel: 'Delete', danger: true,
    });
    if (!ok) return;
    await api('DELETE', `/api/targets/${enc(t.id)}`, {});
    toast(`Target “${t.name}” deleted`, 'ok');
    await app.reloadTargets();
  };

  return (
    <>
      <Panel title="Backup targets" flush>
        {!app.targets.length ? <Empty>No backup targets yet. Add an SMB share or a Proxmox Backup Server below.</Empty> : (
          <table className="table">
            <thead><tr><th>Name</th><th>Kind</th><th>Location</th><th>Keep</th><th>Status</th><th /></tr></thead>
            <tbody>
              {app.targets.map((t) => {
                const r = results[t.id];
                return (
                  <tr key={t.id}>
                    <td><strong>{t.name}</strong></td>
                    <td><KindBadge kind={t.kind} /></td>
                    <td className="wrap mono">{t.location}</td>
                    <td>{t.keep}</td>
                    <td>
                      {!r ? <span className="muted">not tested</span>
                        : r.state === 'testing' ? <span className="task-status"><Spinner />testing…</span>
                          : <>
                            <Badge kind={r.state === 'ok' ? 'ok' : 'err'} title={r.message}>{r.state === 'ok' ? 'OK' : 'Failed'}</Badge>
                            {r.message && <div className="small muted wrap">{r.message}</div>}
                          </>}
                    </td>
                    <td className="actions-cell">
                      <div className="actions">
                        <ActionButton className="small" onClick={() => test(t)}>Test</ActionButton>
                        <ActionButton className="small danger" onClick={() => remove(t)}>Delete</ActionButton>
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </Panel>
      <Panel title="Add target"><AddTargetForm /></Panel>
      {app.targets.length > 0 && <Panel title="Recover from offsite"><RecoverForm /></Panel>}
    </>
  );
}

const SECRET_HINT = 'Stored on this Mac in an owner-only file; never shown again.';
const emptyForm = {
  name: '', keep: '7', smbUrl: '', smbPassword: '',
  pbsHost: '', pbsPort: '8007', pbsDatastore: '', pbsNamespace: '', pbsAuthId: '', pbsSecret: '', pbsFingerprint: '',
};

function AddTargetForm() {
  const app = useApp();
  const { toast, report } = useToast();
  const [kind, setKind] = useState<'smb' | 'pbs'>('smb');
  const [f, setF] = useState(emptyForm);
  const [busy, setBusy] = useState(false);
  const bind = (key: keyof typeof emptyForm) => ({ value: f[key], onChange: (e: { target: { value: string } }) => setF({ ...f, [key]: e.target.value }) });

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    const body: Record<string, unknown> = { name: f.name.trim(), kind, keep: parseInt(f.keep, 10) };
    if (kind === 'smb') {
      body.smb = { url: f.smbUrl.trim(), password: f.smbPassword };
    } else {
      body.pbs = {
        host: f.pbsHost.trim(), port: parseInt(f.pbsPort, 10), datastore: f.pbsDatastore.trim(),
        namespace: f.pbsNamespace.trim() || null, authId: f.pbsAuthId.trim(), secret: f.pbsSecret,
        fingerprint: f.pbsFingerprint.trim().toLowerCase() || null,
      };
    }
    setBusy(true);
    try {
      const t = await api<Target>('POST', '/api/targets', body);
      toast(`Target “${t?.name ?? f.name}” added`, 'ok');
      setF(emptyForm);
      setKind('smb');
      await app.reloadTargets();
    } catch (err) {
      report(err);
    } finally {
      setBusy(false);
    }
  };

  const noAuto = { autoComplete: 'off', spellCheck: false } as const;
  return (
    <form autoComplete="off" onSubmit={submit}>
      <div className="form-grid">
        <div className="field span2">
          <span>Kind</span>
          <Segmented name="kind" value={kind} onChange={setKind} options={[['smb', 'SMB share'], ['pbs', 'Proxmox Backup Server']]} />
        </div>
        <Field label="Name"><input type="text" required maxLength={64} placeholder="e.g. nas" {...noAuto} {...bind('name')} /></Field>
        <Field label="Keep" hint="Snapshots kept per VM on this target"><input type="number" required min={1} max={999} step={1} {...bind('keep')} /></Field>
        {kind === 'smb' ? <>
          <Field label="URL" hint="smb://user@host/share[/path]" className="span2">
            <input type="text" required placeholder="smb://user@host/share/path" pattern={'smb://[^@/\\s]+@[^/\\s]+/\\S+'}
              title="smb://user@host/share[/path]" {...noAuto} {...bind('smbUrl')} />
          </Field>
          <Field label="Password" hint={SECRET_HINT} className="span2"><input type="password" autoComplete="new-password" {...bind('smbPassword')} /></Field>
        </> : <>
          <Field label="Host"><input type="text" required placeholder="pbs.lan or 192.168.1.20" {...noAuto} {...bind('pbsHost')} /></Field>
          <Field label="Port"><input type="number" required min={1} max={65535} step={1} {...bind('pbsPort')} /></Field>
          <Field label="Datastore"><input type="text" required placeholder="datastore" {...noAuto} {...bind('pbsDatastore')} /></Field>
          <Field label="Namespace"><input type="text" placeholder="optional" {...noAuto} {...bind('pbsNamespace')} /></Field>
          <Field label="Auth ID" hint="API token: user@realm!tokenname">
            <input type="text" required placeholder="user@pbs!proxmacs" pattern={'[^@\\s]+@[^!\\s]+![^\\s]+'} title="user@realm!tokenname" {...noAuto} {...bind('pbsAuthId')} />
          </Field>
          <Field label="Token secret" hint={SECRET_HINT}>
            <input type="password" required placeholder="token secret" autoComplete="new-password" {...bind('pbsSecret')} />
          </Field>
          <Field label="TLS fingerprint" hint="SHA-256, needed for self-signed certificates." className="span2">
            <input type="text" placeholder="aa:bb:cc:… (optional)" pattern="([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}"
              title="SHA-256 fingerprint: 32 hex byte pairs separated by colons" {...noAuto} {...bind('pbsFingerprint')} />
          </Field>
        </>}
      </div>
      <div className="form-actions">
        <button type="submit" className="btn primary" disabled={busy}>{busy && <Spinner />}Add target</button>
      </div>
    </form>
  );
}

/** Browse a target's snapshots by VM name, also for VMs that no longer exist here. */
function RecoverForm() {
  const app = useApp();
  const [targetId, setTargetId] = useState(app.targets[0]?.id ?? '');
  const [vm, setVM] = useState('');
  const [query, setQuery] = useState<{ targetId: string; vm: string; n: number } | null>(null);
  const effectiveTarget = app.target(targetId) ? targetId : app.targets[0]?.id ?? '';

  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (!effectiveTarget || !vm.trim()) return;
    setQuery({ targetId: effectiveTarget, vm: vm.trim(), n: (query?.n ?? 0) + 1 });
  };

  return (
    <form onSubmit={submit}>
      <p className="muted">
        Pulling copies a snapshot into local backups; if the VM does not exist anymore it is recreated from the snapshot.
      </p>
      <div className="form-row">
        <Field label="Target">
          <select value={effectiveTarget} onChange={(e) => setTargetId(e.target.value)}>
            {app.targets.map((t) => <option key={t.id} value={t.id}>{t.name} ({t.kind.toUpperCase()})</option>)}
          </select>
        </Field>
        <Field label="VM name">
          <input type="text" placeholder="VM name" autoComplete="off" spellCheck={false} value={vm} onChange={(e) => setVM(e.target.value)} />
        </Field>
        <button type="submit" className="btn">List snapshots</button>
      </div>
      {query && (
        <div className="recover-results">
          <SnapshotBrowser key={`${query.targetId}/${query.vm}/${query.n}`} targetId={query.targetId} vm={query.vm} autoLoad />
        </div>
      )}
    </form>
  );
}
