import { useState, type FormEvent } from 'react';
import { api, enc } from '../../api';
import type { Navigate } from '../../components/Shell';
import { useToast } from '../../components/Toasts';
import { Panel, Spinner } from '../../components/ui';
import { useApp } from '../../store';
import type { VM } from '../../types';
import { GuestFields, guestForm, guestPayload, guestProblem } from './GuestFields';

export function CloudInitView({ vm }: { vm: VM; navigate: Navigate }) {
  const app = useApp();
  const { toast, report } = useToast();
  const [form, setForm] = useState(() => guestForm(vm.cloudInit));
  const [busy, setBusy] = useState(false);
  const pristine = JSON.stringify(form) === JSON.stringify(guestForm(vm.cloudInit));

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    const problem = guestProblem(form);
    if (problem) {
      toast(problem);
      return;
    }
    setBusy(true);
    try {
      const updated = await api<VM>('PUT', `/api/vms/${enc(vm.name)}/cloudinit`, {
        ...guestPayload(form),
        password: form.password || null,
        removePassword: form.removePassword,
      });
      app.updateVM(updated);
      setForm(guestForm(updated.cloudInit));
      toast(vm.state === 'running'
        ? `Cloud-init settings saved. Shut down and start ${vm.name} to apply them.`
        : `Cloud-init settings saved; applied when ${vm.name} next starts.`, 'ok');
    } catch (err) {
      report(err);
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      {vm.seedPending && (
        <div className="note warn">These settings changed while the VM was running. Shut it down and start it again to apply them.</div>
      )}
      {!vm.hasSeed && (
        <div className="note">
          This VM has no cloud-init seed (it was recreated from a backup). Saving creates one; cloud-init then applies these settings on the next start.
        </div>
      )}
      <Panel title="Cloud-Init" narrow>
        <form onSubmit={submit} autoComplete="off">
          <fieldset disabled={busy}>
            <GuestFields value={form} onChange={setForm} passwordState={vm.cloudInit.password} natHint={vm.network.mode === 'nat'} />
            <p className="muted small spaced">
              Saving rebuilds the VM’s cloud-init seed with a new instance ID, so cloud-init re-applies the user, password, SSH keys
              and network on the next start. SSH host keys are kept.
            </p>
            <div className="form-actions">
              <button type="button" className="btn" disabled={pristine} onClick={() => setForm(guestForm(vm.cloudInit))}>Reset</button>
              <button type="submit" className="btn primary" disabled={pristine}>{busy && <Spinner />}Save</button>
            </div>
          </fieldset>
        </form>
      </Panel>
    </>
  );
}
