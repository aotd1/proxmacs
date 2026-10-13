import { useState, type FormEvent } from 'react';
import { useConfirm } from '../../components/Modal';
import { useToast } from '../../components/Toasts';
import { Badge, Field, KV, Loading, Meter, Panel, Spinner } from '../../components/ui';
import { fmtBytes, plural } from '../../format';
import { usePoller } from '../../hooks';
import { useApp } from '../../store';
import type { StorageKind, StorageStatus, Volume } from '../../types';

const LABELS: Record<StorageKind, { title: string; noun: string; folder: string }> = {
  vms: { title: 'VM storage', noun: 'VM storage', folder: 'VMs' },
  backups: { title: 'Local backups', noun: 'backups', folder: 'Backups' },
};

export function StorageView() {
  const { storage, reloadStorage } = useApp();
  usePoller(reloadStorage, 3000);
  if (!storage) return <Loading what="Loading storage…" />;
  return (
    <>
      {storage.busy && (
        <div className="note"><Spinner /> Moving {LABELS[storage.busy].noun}… VMs can’t be started or backed up until it finishes; progress is in the task log.</div>
      )}
      <div className="cols">
        <StoragePanel kind="vms" status={storage} />
        <StoragePanel kind="backups" status={storage} />
      </div>
      <div className="muted small prose">
        <p>
          VM disks and local backups can live on an external drive formatted as APFS; settings, cloud-init seeds and logs stay on this Mac.
          Backups are instant clones when they share a drive with the VMs, and copies otherwise (the VM is frozen only for the clone).
        </p>
        <p>
          While a drive is disconnected its VMs show as <em>offline</em> and nothing is written in its place. VMs that start on login wait
          a few minutes for the drive to appear. Shut VMs down before ejecting the drive.
        </p>
      </div>
    </>
  );
}

function StoragePanel({ kind, status }: { kind: StorageKind; status: StorageStatus }) {
  const app = useApp();
  const location = status[kind];
  const label = LABELS[kind];
  const [editing, setEditing] = useState(false);
  const volume = location.volume;
  const used = volume && volume.totalBytes ? 1 - volume.freeBytes / volume.totalBytes : 0;
  const fixed = kind === 'vms' && status.vmsFixed;

  return (
    <Panel title={label.title} extra={!editing && !fixed && (
      <button type="button" className="btn small" disabled={!!status.busy} onClick={() => setEditing(true)}>Change location</button>
    )}>
      <KV rows={[
        ['Location', <span className="copy-line">
          <span className="mono wrap">{location.path}</span>
          {location.default ? <Badge>default</Badge> : <Badge kind="info">custom</Badge>}
        </span>],
        ['Status', location.available
          ? <Badge kind="ok">available</Badge>
          : <span className="copy-line"><Badge kind="err">unavailable</Badge><span className="muted">Connect the drive holding this folder.</span></span>],
        volume && ['Drive', `${volume.name} · ${volume.fileSystem.toUpperCase()} · ${volume.internal ? 'internal' : 'external'}`],
        volume && ['Space', <div>
          {fmtBytes(volume.freeBytes)} free of {fmtBytes(volume.totalBytes)}
          {volume.totalBytes > 0 && <Meter fraction={used} />}
        </div>],
      ]} />
      {fixed && <p className="muted small spaced">Set by the TART_HOME environment variable of the Proxmacs process.</p>}
      {editing && <MoveForm kind={kind} status={status} onDone={() => { setEditing(false); void app.reloadStorage(); }} />}
    </Panel>
  );
}

type Choice = { type: 'default' } | { type: 'volume'; volume: Volume } | { type: 'custom' };

function MoveForm({ kind, status, onDone }: { kind: StorageKind; status: StorageStatus; onDone: () => void }) {
  const app = useApp();
  const confirm = useConfirm();
  const { report } = useToast();
  const location = status[kind];
  const label = LABELS[kind];
  const suggested = (v: Volume) => `${v.path}/Proxmacs/${label.folder}`;
  const firstAPFS = status.volumes.find((v) => v.fileSystem === 'apfs');
  const [choice, setChoice] = useState<Choice>(
    firstAPFS ? { type: 'volume', volume: firstAPFS } : location.default ? { type: 'custom' } : { type: 'default' });
  const [path, setPath] = useState(firstAPFS ? suggested(firstAPFS) : '');
  const [busy, setBusy] = useState(false);

  const running = kind === 'vms' ? app.vms.filter((v) => v.state === 'running') : [];
  const choose = (next: Choice) => {
    setChoice(next);
    if (next.type === 'volume') setPath(suggested(next.volume));
  };

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    const target = choice.type === 'default' ? null : path.trim();
    const where = target ?? 'the internal disk (default)';
    const ok = await confirm({
      title: `Move ${label.noun}`,
      message: kind === 'vms'
        ? <>Every VM’s disk moves to <strong>{where}</strong>. Large disks take a while to copy between drives; VMs can’t be started until the move has finished.</>
        : <>Existing local backups move to <strong>{where}</strong>; new backups are stored there.</>,
      confirmLabel: 'Move',
    });
    if (!ok) return;
    setBusy(true);
    try {
      await app.startTask('PUT', '/api/host/storage', { kind, path: target }, `Move ${label.noun}`);
      app.setTasksOpen(true);
      onDone();
    } catch (err) {
      report(err);
      setBusy(false);
    }
  };

  return (
    <form className="storage-form" onSubmit={submit}>
      <h4 className="section-title">Move {label.noun} to</h4>
      <div className="radio-list">
        <label className={`radio-row${location.default ? ' disabled' : ''}`}>
          <input type="radio" name={`${kind}-dest`} checked={choice.type === 'default'} disabled={location.default}
            onChange={() => choose({ type: 'default' })} />
          <span><strong>This Mac</strong> <span className="muted">(default){location.default ? ' — current' : ''}</span></span>
        </label>
        {status.volumes.map((v) => {
          const apfs = v.fileSystem === 'apfs';
          return (
            <label key={v.path} className={`radio-row${apfs ? '' : ' disabled'}`}>
              <input type="radio" name={`${kind}-dest`} disabled={!apfs}
                checked={choice.type === 'volume' && choice.volume.path === v.path} onChange={() => choose({ type: 'volume', volume: v })} />
              <span>
                <strong>{v.name}</strong> <span className="muted">{v.fileSystem.toUpperCase()} · {fmtBytes(v.freeBytes)} free of {fmtBytes(v.totalBytes)}</span>
                {!apfs && <div className="hint">Needs APFS: reformat the drive in Disk Utility to use it.</div>}
              </span>
            </label>
          );
        })}
        <label className="radio-row">
          <input type="radio" name={`${kind}-dest`} checked={choice.type === 'custom'} onChange={() => choose({ type: 'custom' })} />
          <span><strong>Another folder</strong></span>
        </label>
        {!status.volumes.length && <p className="muted small">No external drives are connected.</p>}
      </div>
      {choice.type !== 'default' && (
        <Field label="Folder" hint="A new or empty folder, or one that already holds Proxmacs data of this kind (e.g. a reconnected drive).">
          <input type="text" required spellCheck={false} autoComplete="off" className="mono" value={path}
            placeholder={`/Volumes/External/Proxmacs/${label.folder}`} onChange={(e) => setPath(e.target.value)} />
        </Field>
      )}
      {running.length > 0 && (
        <div className="note warn">Shut down {plural(running.length, 'running VM')} first ({running.map((v) => v.name).join(', ')}).</div>
      )}
      <div className="actions">
        <button type="button" className="btn" onClick={onDone}>Cancel</button>
        <button type="submit" className="btn primary" disabled={busy || running.length > 0 || !!status.busy}>{busy && <Spinner />}Move</button>
      </div>
    </form>
  );
}
