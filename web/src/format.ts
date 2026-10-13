import type { BackupPolicy, NetInterface, NetworkConfig } from './types';

export const pad2 = (n: number) => String(n).padStart(2, '0');

export function fmtBytes(b: number | null | undefined): string {
  if (b == null || !Number.isFinite(b)) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let i = 0;
  while (Math.abs(b) >= 1024 && i < units.length - 1) { b /= 1024; i++; }
  return `${b.toFixed(i >= 3 ? 1 : 0)} ${units[i]}`;
}

export function fmtMemMB(mb: number | null | undefined): string {
  if (mb == null) return '—';
  if (mb >= 1024) {
    const gb = mb / 1024;
    return `${Number.isInteger(gb) ? gb : gb.toFixed(1)} GB`;
  }
  return `${mb} MB`;
}

const dateFmt = new Intl.DateTimeFormat(undefined, { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
export const timeFmt = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' });

export function fmtDate(iso: string | null | undefined, fmt = dateFmt): string {
  if (!iso) return '—';
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? String(iso) : fmt.format(d);
}

export function fmtDuration(startIso: string, endIso: string | null): string {
  const s = new Date(startIso).getTime();
  const e = endIso ? new Date(endIso).getTime() : Date.now();
  if (Number.isNaN(s) || Number.isNaN(e)) return '';
  let sec = Math.max(0, Math.round((e - s) / 1000));
  const hrs = Math.floor(sec / 3600); sec %= 3600;
  const min = Math.floor(sec / 60); sec %= 60;
  if (hrs) return `${hrs}h ${min}m`;
  if (min) return `${min}m ${sec}s`;
  return `${sec}s`;
}

export function interfaceLabel(device: string | null, interfaces: NetInterface[]): string {
  if (!device) return 'default interface';
  const i = interfaces.find((x) => x.device === device);
  return i ? `${i.name} (${device})` : device;
}

export function networkLabel(net: NetworkConfig | null | undefined, interfaces: NetInterface[]): string {
  if (!net) return '—';
  if (net.mode === 'bridged') return `Bridged — ${interfaceLabel(net.interface, interfaces)}`;
  if (net.mode === 'nat') return 'NAT (shared)';
  return String(net.mode || '—');
}

export function backupLabel(b: BackupPolicy | null | undefined): string {
  if (!b) return '—';
  return b.daily ? `Daily at ${pad2(b.hour)}:00, keep ${b.keep}` : `Scheduled backups off (keep ${b.keep})`;
}

export function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? '' : 's'}`;
}
