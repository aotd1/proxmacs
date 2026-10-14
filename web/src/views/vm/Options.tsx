import { useState, type FormEvent } from 'react';
import { api, enc } from '../../api';
import { useToast } from '../../components/Toasts';
import { Field, Panel, Spinner, Tags } from '../../components/ui';
import { useApp } from '../../store';
import type { VM } from '../../types';

const parseTags = (text: string) => [...new Set(text.split(/[\s,]+/).map((t) => t.trim().toLowerCase()).filter(Boolean))];

export function OptionsView({ vm }: { vm: VM }) {
  const app = useApp();
  const { toast, report } = useToast();
  const server = {
    autostart: vm.autostart,
    order: vm.startOrder != null ? String(vm.startOrder) : '',
    delay: String(vm.startDelay),
    tags: vm.tags.join(', '),
  };
  const [edits, setEdits] = useState<Partial<typeof server>>({});
  const [busy, setBusy] = useState(false);
  const f = { ...server, ...edits };
  const set = (patch: Partial<typeof server>) => setEdits({ ...edits, ...patch });
  const changed = Object.keys(edits).some((k) => edits[k as keyof typeof server] !== server[k as keyof typeof server]);
  const badTag = parseTags(f.tags).find((t) => !/^[a-z0-9][a-z0-9_.+-]{0,31}$/.test(t));

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    try {
      app.updateVM(await api<VM>('PATCH', `/api/vms/${enc(vm.name)}`, {
        autostart: f.autostart, startOrder: f.order.trim() === '' ? null : parseInt(f.order, 10),
        startDelay: parseInt(f.delay, 10) || 0, tags: parseTags(f.tags),
      }));
      setEdits({});
      toast(`Options of ${vm.name} saved`, 'ok');
    } catch (err) {
      report(err);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Panel title="Options" narrow>
      <form onSubmit={submit}>
        <fieldset disabled={busy}>
          <div className="form-grid">
            <div className="field span2">
              <label className="check">
                <input type="checkbox" className="switch" checked={f.autostart} disabled={vm.template}
                  onChange={(e) => set({ autostart: e.target.checked })} />
                Start on login
              </label>
              <span className="hint">{vm.template ? 'Templates can’t be started.' : 'The VM starts when you log in to this Mac, even if Proxmacs isn’t open.'}</span>
            </div>
            <Field label="Start order" hint="VMs that start on login start in this order, lowest first; empty = after the ordered ones.">
              <input type="number" min={0} max={9999} step={1} placeholder="any" value={f.order} onChange={(e) => set({ order: e.target.value })} />
            </Field>
            <Field label="Startup delay (seconds)" hint="Wait this long after starting this VM before starting the next one in order.">
              <input type="number" min={0} max={3600} step={1} required value={f.delay} onChange={(e) => set({ delay: e.target.value })} />
            </Field>
            <Field label="Tags" className="span2"
              hint={badTag ? <span className="error-text">“{badTag}”: tags are lowercase letters, digits and . _ + - (up to 32)</span>
                : <>Comma-separated, e.g. <span className="mono">web, prod</span>. Filter VMs by tag in the resource tree.</>}>
              <input type="text" autoComplete="off" spellCheck={false} value={f.tags} onChange={(e) => set({ tags: e.target.value })} />
            </Field>
            {!!parseTags(f.tags).length && !badTag && <div className="span2"><Tags tags={parseTags(f.tags)} /></div>}
          </div>
          <div className="form-actions">
            <button type="button" className="btn" disabled={!changed} onClick={() => setEdits({})}>Reset</button>
            <button type="submit" className="btn primary" disabled={!changed || !!badTag}>{busy && <Spinner />}Save</button>
          </div>
        </fieldset>
      </form>
    </Panel>
  );
}
