import { useState } from 'react';
import { api, enc } from '../../api';
import { useConfirm } from '../../components/Modal';
import type { Navigate } from '../../components/Shell';
import { useToast } from '../../components/Toasts';
import { ActionButton, Badge, KV, Panel, Spinner, StateBadge } from '../../components/ui';
import { backupLabel, fmtMemMB, networkLabel } from '../../format';
import { copyText } from '../../hooks';
import { useApp } from '../../store';
import type { VM } from '../../types';
import { vmBackup, vmDelete, vmStart, vmStop } from './actions';

export function VMSummary({ vm, navigate }: { vm: VM; navigate: Navigate }) {
  const app = useApp();
  const confirm = useConfirm();
  const running = vm.state === 'running';
  const canStart = vm.state === 'stopped' || vm.state === 'suspended';
  const ci = vm.cloudInit;
  const edit = (tab: string) => (
    <button type="button" className="btn small" onClick={() => navigate({ type: 'vm', name: vm.name, tab })}>Edit</button>
  );
  const offsite = vm.offsite.targets.length
    ? `${vm.offsite.targets.map((id) => app.target(id)?.name ?? id).join(', ')} — ${vm.offsite.auto ? 'pushed automatically after each backup' : 'manual push only'}`
    : 'None';

  return (
    <>
      <div className="toolbar">
        <ActionButton className="primary" disabled={!canStart} title={canStart ? null : running ? 'Already running' : `Cannot start a ${vm.state} VM`}
          onClick={() => vmStart(app.startTask, vm)}>Start</ActionButton>
        <ActionButton disabled={!running} title={running ? null : 'The VM is not running'} onClick={() => vmStop(app.startTask, vm)}>Shutdown</ActionButton>
        <ActionButton disabled={vm.state === 'missing' || vm.state === 'offline'} title={vm.state === 'missing' || vm.state === 'offline' ? `The VM is ${vm.state}` : null}
          onClick={() => vmBackup(app.startTask, vm)}>Back up now</ActionButton>
        <div className="spacer" />
        <ActionButton className="danger" disabled={vm.state === 'offline'} title={vm.state === 'offline' ? 'VM storage is not connected' : null}
          onClick={() => vmDelete(app.startTask, confirm, vm)}>Delete</ActionButton>
      </div>
      {vm.seedPending && (
        <div className="note warn">Cloud-init settings changed while the VM was running. Shut it down and start it again to apply them.</div>
      )}
      {vm.state === 'offline' && (
        <div className="note warn">
          VM storage ({app.storage?.vms.path ?? 'external drive'}) is not connected. Connect the drive, or{' '}
          <button type="button" className="link" onClick={() => navigate({ type: 'host', tab: 'storage' })}>change the storage location</button>.
        </div>
      )}
      {vm.state === 'missing' && (
        <div className="note">This VM is registered with Proxmacs but its Tart VM was not found. Restore it from the Backups tab, or pull a snapshot from the Offsite tab.</div>
      )}
      <div className="grid2">
        <Panel title="Status">
          <KV rows={[
            ['State', <span className="copy-line"><StateBadge state={vm.state} />{vm.activity && <Badge kind="info"><Spinner />{vm.activity}</Badge>}</span>],
            ['IP address', <IPCell vm={vm} />],
            ['Network', networkLabel(vm.network, app.interfaces)],
            ['Start on login', <AutostartSwitch vm={vm} />],
          ]} />
        </Panel>
        <Panel title="Hardware" extra={edit('hardware')}>
          <KV rows={[
            ['CPUs', vm.cpus != null ? String(vm.cpus) : '—'],
            ['Memory', fmtMemMB(vm.memoryMB)],
            ['Disk', vm.diskGB != null ? `${vm.diskGB} GB` : '—'],
            !!vm.image && ['Image', vm.image],
          ]} />
        </Panel>
        <Panel title="Cloud-Init" extra={edit('cloudinit')}>
          <KV rows={[
            ['User', <span className="mono">{ci.user}</span>],
            ['Password', { set: 'set', none: 'none', unknown: 'unchanged since creation' }[ci.password]],
            ['SSH keys', ci.sshKeys.length ? `${ci.sshKeys.length} key${ci.sshKeys.length === 1 ? '' : 's'}` : 'none'],
            ['IPv4', ci.network.dhcp ? 'DHCP' : <span className="mono">{ci.network.address}{ci.network.gateway && ` via ${ci.network.gateway}`}</span>],
          ]} />
        </Panel>
        <Panel title="Protection">
          <KV rows={[
            ['Local backups', backupLabel(vm.backup)],
            ['Offsite', offsite],
          ]} />
        </Panel>
      </div>
    </>
  );
}

function IPCell({ vm }: { vm: VM }) {
  const [copied, setCopied] = useState<string | null>(null);
  if (!vm.ip) return <span className="muted">{vm.state === 'running' ? 'waiting for an address…' : '—'}</span>;
  const ssh = `ssh ${vm.cloudInit.user}@${vm.ip}`;
  const copy = async () => {
    setCopied((await copyText(ssh)) ? 'Copied' : 'Copy failed');
    window.setTimeout(() => setCopied(null), 1500);
  };
  return (
    <div>
      <div className="mono">{vm.ip}</div>
      <div className="copy-line spaced">
        <code>{ssh}</code>
        <button type="button" className="btn small" onClick={copy}>{copied ?? 'Copy'}</button>
      </div>
    </div>
  );
}

function AutostartSwitch({ vm }: { vm: VM }) {
  const app = useApp();
  const { report } = useToast();
  const [busy, setBusy] = useState(false);
  const toggle = async (autostart: boolean) => {
    setBusy(true);
    try {
      app.updateVM(await api<VM>('PATCH', `/api/vms/${enc(vm.name)}`, { autostart }));
    } catch (e) {
      report(e);
    } finally {
      setBusy(false);
    }
  };
  return (
    <label className="check">
      <input type="checkbox" className="switch" aria-label="Start on login" checked={vm.autostart} disabled={busy}
        onChange={(e) => toggle(e.target.checked)} />
      {vm.autostart ? 'On' : 'Off'}
    </label>
  );
}
