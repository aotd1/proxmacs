import { api, enc } from '../../api';
import type { ConfirmOptions } from '../../components/Modal';
import type { VM } from '../../types';

type StartTask = (method: string, path: string, body: unknown, label: string) => Promise<void>;
type Confirm = (options: ConfirmOptions) => Promise<boolean>;

const post = (startTask: StartTask, vm: VM, action: string, label: string) =>
  startTask('POST', `/api/vms/${enc(vm.name)}/${action}`, {}, `${label} ${vm.name}`);

export const vmStart = (startTask: StartTask, vm: VM) => post(startTask, vm, 'start', 'Start');
export const vmStop = (startTask: StartTask, vm: VM) => post(startTask, vm, 'stop', 'Shutdown');
export const vmReboot = (startTask: StartTask, vm: VM) => post(startTask, vm, 'reboot', 'Reboot');

export async function vmPowerOff(startTask: StartTask, confirm: Confirm, vm: VM) {
  const ok = await confirm({
    title: `Stop ${vm.name}`,
    message: `Turn “${vm.name}” off at once, like pulling the plug? Unsaved data in the guest is lost. Use Shutdown for a clean stop.`,
    confirmLabel: 'Stop', danger: true,
  });
  if (ok) await post(startTask, vm, 'poweroff', 'Stop');
}

export async function vmReset(startTask: StartTask, confirm: Confirm, vm: VM) {
  const ok = await confirm({
    title: `Reset ${vm.name}`,
    message: `Turn “${vm.name}” off at once and start it again? Unsaved data in the guest is lost. Use Reboot for a clean restart.`,
    confirmLabel: 'Reset', danger: true,
  });
  if (ok) await post(startTask, vm, 'reset', 'Reset');
}

export async function vmSetTemplate(confirm: Confirm, vm: VM, template: boolean): Promise<VM | null> {
  if (template) {
    const ok = await confirm({
      title: `Convert ${vm.name} to a template`,
      message: `A template can’t be started, only cloned. Use it as the base for new VMs; you can convert it back later.`,
      confirmLabel: 'Convert',
    });
    if (!ok) return null;
  }
  return api<VM>('POST', `/api/vms/${enc(vm.name)}/template`, { template });
}

export async function vmDelete(startTask: StartTask, confirm: Confirm, vm: VM) {
  const ok = await confirm({
    title: `Delete ${vm.template ? 'template' : 'VM'} ${vm.name}`,
    message: `This permanently deletes “${vm.name}” and its disks. Local backups and offsite snapshots are kept.`,
    confirmLabel: 'Delete', danger: true, requireText: vm.name,
  });
  if (ok) await startTask('DELETE', `/api/vms/${enc(vm.name)}`, {}, `Delete ${vm.name}`);
}
