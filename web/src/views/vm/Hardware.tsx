import { useState, type FormEvent } from 'react';
import { api, enc } from '../../api';
import type { Navigate } from '../../components/Shell';
import { useToast } from '../../components/Toasts';
import { Field, Panel, Segmented, Spinner } from '../../components/ui';
import { fmtMemMB } from '../../format';
import { useApp } from '../../store';
import type { VM } from '../../types';

/** Memory in MB, in 256 MB steps from 512 MB up to the host's RAM. */
export function MemoryField({ value, onChange, hostBytes }: { value: string; onChange: (value: string) => void; hostBytes?: number }) {
  const hostMB = hostBytes ? Math.floor(hostBytes / 2 ** 20) : undefined;
  const mb = parseInt(value, 10);
  return (
    <Field label="Memory (MB)" hint={`${Number.isFinite(mb) ? `${fmtMemMB(mb)} · ` : ''}multiples of 256 MB${hostMB ? `, host has ${fmtMemMB(hostMB)}` : ''}`}>
      <input type="number" required min={512} max={hostMB} step={256} value={value} onChange={(e) => onChange(e.target.value)} />
    </Field>
  );
}

export function HardwareView({ vm, navigate }: { vm: VM; navigate: Navigate }) {
  const app = useApp();
  const { toast, report } = useToast();
  const server = {
    cpus: String(vm.cpus ?? 2),
    memoryMB: String(vm.memoryMB ?? 2048),
    diskGB: String(vm.diskGB ?? 20),
    mode: vm.network.mode,
    iface: vm.network.interface ?? app.interfaces.find((i) => i.default)?.device ?? app.interfaces[0]?.device ?? '',
  };
  // The form shows the server's values overlaid with the user's edits.
  const [edits, setEdits] = useState<Partial<typeof server>>({});
  const [busy, setBusy] = useState(false);
  const f = { ...server, ...edits };
  const set = (patch: Partial<typeof server>) => setEdits({ ...edits, ...patch });

  const stopped = vm.state === 'stopped';
  const hostCPUs = Math.max(1, app.host?.cpus ?? 4);
  const changed = f.cpus !== server.cpus || f.memoryMB !== server.memoryMB || f.diskGB !== server.diskGB
    || f.mode !== server.mode || (f.mode === 'bridged' && f.iface !== vm.network.interface);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    try {
      const updated = await api<VM>('PUT', `/api/vms/${enc(vm.name)}/hardware`, {
        cpus: parseInt(f.cpus, 10), memoryMB: parseInt(f.memoryMB, 10), diskGB: parseInt(f.diskGB, 10),
        network: { mode: f.mode, interface: f.mode === 'bridged' ? f.iface : null },
      });
      app.updateVM(updated);
      setEdits({});
      toast(`Hardware of ${vm.name} updated`, 'ok');
    } catch (err) {
      report(err);
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      {!stopped && (
        <div className="note">
          {vm.state === 'running' ? 'Shut down the VM to change its hardware.' : `The VM is ${vm.state}; hardware can only be changed while it is stopped.`}
        </div>
      )}
      <Panel title="Hardware">
        <form onSubmit={submit}>
          <fieldset disabled={!stopped || busy}>
            <div className="form-grid">
              <Field label="CPUs" hint={`Host has ${hostCPUs}`}>
                <select value={f.cpus} onChange={(e) => set({ cpus: e.target.value })}>
                  {Array.from({ length: hostCPUs }, (_, i) => <option key={i} value={String(i + 1)}>{i + 1}</option>)}
                </select>
              </Field>
              <MemoryField value={f.memoryMB} onChange={(memoryMB) => set({ memoryMB })} hostBytes={app.host?.memoryBytes} />
              <Field label="Disk (GB)" hint="Disks can only grow. The root filesystem expands on the next boot.">
                <input type="number" required min={vm.diskGB ?? 1} max={16384} step={1} value={f.diskGB} onChange={(e) => set({ diskGB: e.target.value })} />
              </Field>
              <div className="field">
                <span>Network</span>
                <Segmented name="mode" value={f.mode} onChange={(mode) => set({ mode })}
                  options={[['bridged', 'Bridged', !app.interfaces.length], ['nat', 'NAT']]} />
                <span className="hint">The MAC address stays the same.</span>
              </div>
              {f.mode === 'bridged' && (
                <Field label="Interface">
                  <select value={f.iface} onChange={(e) => set({ iface: e.target.value })}>
                    {app.interfaces.map((i) => <option key={i.device} value={i.device}>{i.name} ({i.device}){i.default ? ' — default' : ''}</option>)}
                    {f.iface && !app.interfaces.some((i) => i.device === f.iface) && <option value={f.iface}>{f.iface}</option>}
                  </select>
                </Field>
              )}
            </div>
            {f.mode !== vm.network.mode && !vm.cloudInit.network.dhcp && (
              <p className="note warn">This VM has a static address. Update it on the{' '}
                <button type="button" className="link" onClick={() => navigate({ type: 'vm', name: vm.name, tab: 'cloudinit' })}>Cloud-Init</button>{' '}
                tab to match the new network.</p>
            )}
            <div className="form-actions">
              <button type="button" className="btn" disabled={!changed} onClick={() => setEdits({})}>Reset</button>
              <button type="submit" className="btn primary" disabled={!changed}>{busy && <Spinner />}Save</button>
            </div>
          </fieldset>
        </form>
      </Panel>
    </>
  );
}
