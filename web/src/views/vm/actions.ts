import { enc } from '../../api';
import type { ConfirmOptions } from '../../components/Modal';
import type { VM } from '../../types';

type StartTask = (method: string, path: string, body: unknown, label: string) => Promise<void>;
type Confirm = (options: ConfirmOptions) => Promise<boolean>;

export const vmStart = (startTask: StartTask, vm: VM) => startTask('POST', `/api/vms/${enc(vm.name)}/start`, {}, `Start ${vm.name}`);
export const vmStop = (startTask: StartTask, vm: VM) => startTask('POST', `/api/vms/${enc(vm.name)}/stop`, {}, `Shutdown ${vm.name}`);
export const vmBackup = (startTask: StartTask, vm: VM) => startTask('POST', `/api/vms/${enc(vm.name)}/backup`, {}, `Back up ${vm.name}`);

export async function vmDelete(startTask: StartTask, confirm: Confirm, vm: VM) {
  const ok = await confirm({
    title: `Delete VM ${vm.name}`,
    message: `This permanently deletes the VM “${vm.name}” and its disk. Local backups and offsite snapshots are kept.`,
    confirmLabel: 'Delete VM', danger: true, requireText: vm.name,
  });
  if (ok) await startTask('DELETE', `/api/vms/${enc(vm.name)}`, {}, `Delete ${vm.name}`);
}
