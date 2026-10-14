import { useEffect, useRef, useState, type FormEvent } from 'react';
import { api } from '../api';
import { Modal } from '../components/Modal';
import { useToast } from '../components/Toasts';
import { Field, Loading, Segmented, Spinner } from '../components/ui';
import { useApp } from '../store';
import type { Image } from '../types';
import { GuestFields, guestForm, guestPayload, guestProblem, type GuestForm } from './vm/GuestFields';
import { MemoryField } from './vm/Hardware';

export function CreateVMDialog({ onClose }: { onClose: () => void }) {
  const app = useApp();
  const { toast, report } = useToast();
  const [images, setImages] = useState<Image[] | null>(null);
  const [guest, setGuest] = useState<GuestForm | null>(null);
  const [busy, setBusy] = useState(false);

  const hostCPUs = Math.max(1, app.host?.cpus ?? 4);
  const hostGB = app.host?.memoryBytes ? app.host.memoryBytes / 2 ** 30 : 8;
  const defaultIface = app.interfaces.find((i) => i.default) ?? app.interfaces[0];
  const [f, setF] = useState({
    name: '',
    cpus: String(Math.min(2, hostCPUs)),
    memoryMB: String(hostGB >= 16 ? 4096 : 2048),
    diskGB: '20',
    image: 'debian-13',
    mode: (defaultIface ? 'bridged' : 'nat') as 'bridged' | 'nat',
    iface: defaultIface?.device ?? '',
    autostart: false,
    startNow: true,
  });
  const set = (patch: Partial<typeof f>) => setF({ ...f, ...patch });

  const { reloadInterfaces } = app;
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  useEffect(() => {
    let cancelled = false;
    Promise.all([api<Image[]>('GET', '/api/images'), api<string[]>('GET', '/api/host/sshkeys'), reloadInterfaces()]).then(
      ([imageList, keys]) => {
        if (cancelled) return;
        setImages(imageList);
        setGuest({ ...guestForm(undefined, keys), user: imageList.find((i) => i.id === 'debian-13')?.user ?? 'debian' });
      },
      (e) => { if (!cancelled) { report(e); closeRef.current(); } },
    );
    return () => { cancelled = true; };
  }, [reloadInterfaces, report]);

  const nameTaken = !!app.vm(f.name.trim());
  const image = images?.find((i) => i.id === f.image);
  const minDiskGB = image?.sizeBytes ? Math.ceil(image.sizeBytes / 1e9) : 10;

  const chooseImage = (id: string) => {
    const next = images?.find((i) => i.id === id);
    // Follow the distribution's default user unless it was changed by hand.
    if (guest && next?.user && guest.user === (image?.user ?? 'debian')) setGuest({ ...guest, user: next.user });
    set({ image: id });
  };
  const distros = [...new Set(images?.filter((i) => i.distro).map((i) => i.distro!))];
  const imported = images?.filter((i) => i.imported) ?? [];
  const option = (i: Image) => <option key={i.id} value={i.id}>{i.name}{i.cached ? '' : ' (download)'}</option>;

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!guest) return;
    const problem = guestProblem(guest);
    if (problem) {
      toast(problem);
      return;
    }
    const name = f.name.trim();
    setBusy(true);
    try {
      await app.startTask('POST', '/api/vms', {
        name,
        cpus: parseInt(f.cpus, 10),
        memoryMB: parseInt(f.memoryMB, 10),
        diskGB: parseInt(f.diskGB, 10),
        network: { mode: f.mode, interface: f.mode === 'bridged' ? f.iface || null : null },
        image: f.image,
        password: guest.password || null,
        autostart: f.autostart,
        startNow: f.startNow,
        ...guestPayload(guest),
      }, `Create ${name}`);
      app.setTasksOpen(true);
      onClose();
    } catch (err) {
      report(err);
      setBusy(false);
    }
  };

  return (
    <Modal title="Create VM" onClose={onClose} wide>
      {!images || !guest ? <div className="modal-body"><Loading /></div> : (
        <form autoComplete="off" onSubmit={submit}>
          <div className="modal-body">
            <div className="form-grid">
              <Field label="Name" className="span2" hint={nameTaken ? <span className="error-text">A VM with this name already exists</span> : 'Lowercase letters, digits and dashes'}>
                <input type="text" required autoFocus maxLength={63} autoComplete="off" spellCheck={false} autoCapitalize="off"
                  pattern="[a-z0-9][a-z0-9\-]*" title="Lowercase letters, digits and dashes; must start with a letter or digit"
                  placeholder="e.g. web01" value={f.name} onChange={(e) => set({ name: e.target.value.toLowerCase() })} />
              </Field>
              <Field label="CPUs" hint={`Host has ${hostCPUs}`}>
                <select value={f.cpus} onChange={(e) => set({ cpus: e.target.value })}>
                  {Array.from({ length: hostCPUs }, (_, i) => <option key={i} value={String(i + 1)}>{i + 1}</option>)}
                </select>
              </Field>
              <MemoryField value={f.memoryMB} onChange={(memoryMB) => set({ memoryMB })} hostBytes={app.host?.memoryBytes} />
              <Field label="Disk (GB)">
                <input type="number" required min={minDiskGB} max={4096} step={1} value={f.diskGB} onChange={(e) => set({ diskGB: e.target.value })} />
              </Field>
              <Field label="Image" hint={image && !image.cached ? 'Downloaded when the VM is created (or ahead of time under Host → Images)' : undefined}>
                <select required value={f.image} onChange={(e) => chooseImage(e.target.value)}>
                  {distros.map((d) => <optgroup key={d} label={d}>{images.filter((i) => i.distro === d).map(option)}</optgroup>)}
                  {imported.length > 0 && <optgroup label="Imported">{imported.map(option)}</optgroup>}
                </select>
              </Field>
              <div className="field">
                <span>Network</span>
                <Segmented name="mode" value={f.mode} onChange={(mode) => set({ mode })}
                  options={[['bridged', 'Bridged', !app.interfaces.length], ['nat', 'NAT']]} />
                <span className="hint">Bridged: own LAN address. NAT: private address behind this Mac.</span>
              </div>
              {f.mode === 'bridged' && (
                <Field label="Interface">
                  <select value={f.iface} onChange={(e) => set({ iface: e.target.value })}>
                    {app.interfaces.map((i) => <option key={i.device} value={i.device}>{i.name} ({i.device}){i.default ? ' — default' : ''}</option>)}
                  </select>
                </Field>
              )}
            </div>

            <h4 className="section-title">Cloud-Init</h4>
            <GuestFields value={guest} onChange={setGuest} natHint={f.mode === 'nat'} />

            <div className="check-row">
              <label className="check"><input type="checkbox" checked={f.autostart} onChange={(e) => set({ autostart: e.target.checked })} />Start on login</label>
              <label className="check"><input type="checkbox" checked={f.startNow} onChange={(e) => set({ startNow: e.target.checked })} />Start now</label>
            </div>
          </div>
          <div className="modal-footer">
            <button type="button" className="btn" onClick={onClose}>Cancel</button>
            <button type="submit" className="btn primary" disabled={busy || nameTaken}>{busy && <Spinner />}Create</button>
          </div>
        </form>
      )}
    </Modal>
  );
}
