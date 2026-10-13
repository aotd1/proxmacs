import { useEffect, useRef, useState } from 'react';
import { api, enc } from '../../api';
import type { Navigate } from '../../components/Shell';
import { SnapshotBrowser, type SnapshotBrowserHandle } from '../../components/SnapshotBrowser';
import { useToast } from '../../components/Toasts';
import { ActionButton, Empty, KindBadge, Panel } from '../../components/ui';
import { useApp } from '../../store';
import type { Target, VM } from '../../types';

export function OffsiteView({ vm, navigate }: { vm: VM; navigate: Navigate }) {
  const app = useApp();
  return (
    <>
      <Panel title="Offsite settings">
        {!app.targets.length ? (
          <Empty>
            <p>No backup targets configured.</p>
            <button type="button" className="btn" onClick={() => navigate({ type: 'host', tab: 'targets' })}>Manage backup targets</button>
          </Empty>
        ) : <OffsiteSettings vm={vm} />}
      </Panel>
      <p className="muted small">
        Pulling a snapshot copies it into this VM’s local backups; restore it from the Backups tab. If the VM no longer exists, it is recreated from the snapshot.
      </p>
      {app.targets.map((t) => <RemoteSnapshots key={t.id} target={t} vm={vm} />)}
    </>
  );
}

function OffsiteSettings({ vm }: { vm: VM }) {
  const app = useApp();
  const { report } = useToast();
  const [saving, setSaving] = useState(false);
  const chosen = new Set(vm.offsite.targets.map(String));

  const save = async (offsite: VM['offsite']) => {
    setSaving(true);
    try {
      app.updateVM(await api<VM>('PATCH', `/api/vms/${enc(vm.name)}`, { offsite }));
    } catch (e) {
      report(e);
    } finally {
      setSaving(false);
    }
  };
  const toggleTarget = (id: string, on: boolean) => {
    const targets = app.targets.map((t) => t.id).filter((tid) => (tid === id ? on : chosen.has(tid)));
    void save({ targets, auto: vm.offsite.auto });
  };

  return (
    <>
      <label className="check">
        <input type="checkbox" className="switch" checked={vm.offsite.auto} disabled={saving}
          onChange={(e) => void save({ targets: [...chosen], auto: e.target.checked })} />
        <span><strong>Push automatically</strong> after each local backup to the selected targets</span>
      </label>
      <div className="target-checks">
        {app.targets.map((t) => (
          <label key={t.id} className="check">
            <input type="checkbox" checked={chosen.has(t.id)} disabled={saving} onChange={(e) => toggleTarget(t.id, e.target.checked)} />
            <span>
              <strong>{t.name}</strong> <KindBadge kind={t.kind} />
              <div className="muted small mono wrap">{t.location}</div>
            </span>
          </label>
        ))}
      </div>
    </>
  );
}

function RemoteSnapshots({ target, vm }: { target: Target; vm: VM }) {
  const app = useApp();
  const browser = useRef<SnapshotBrowserHandle>(null);
  const [loaded, setLoaded] = useState(false);
  const loadedRef = useRef(false);
  loadedRef.current = loaded;
  const epoch = app.taskEpoch[vm.name] ?? 0;
  // Pushes and pulls change what's on the target.
  useEffect(() => { if (loadedRef.current) void browser.current?.load(); }, [epoch]);

  return (
    <Panel title={`Remote snapshots — ${target.name}`} flush extra={
      <div className="actions">
        <KindBadge kind={target.kind} />
        <ActionButton className="small" onClick={async () => { await browser.current?.load(); setLoaded(true); }}>
          {loaded ? 'Refresh' : 'Load snapshots'}
        </ActionButton>
      </div>
    }>
      <SnapshotBrowser ref={browser} targetId={target.id} vm={vm.name} />
    </Panel>
  );
}
