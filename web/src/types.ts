// Shapes returned by the Proxmacs JSON API (Sources/Proxmacs/Web/WebAPI.swift).

/** 'offline': VM storage is on a drive that is not connected. */
export type VMState = 'running' | 'stopped' | 'suspended' | 'missing' | 'offline' | (string & {});

export interface NetworkConfig {
  mode: 'nat' | 'bridged';
  interface: string | null;
}

export interface GuestIPv4 {
  dhcp: boolean;
  address: string | null;
  gateway: string | null;
  dns: string[];
}

export interface CloudInit {
  user: string;
  /** 'unknown' for VMs created before Proxmacs tracked passwords. */
  password: 'set' | 'none' | 'unknown';
  sshKeys: string[];
  legacy: boolean;
  network: GuestIPv4;
}

export interface BackupPolicy {
  daily: boolean;
  hour: number;
  keep: number;
}

export interface OffsitePolicy {
  targets: string[];
  auto: boolean;
}

export interface VM {
  name: string;
  state: VMState;
  ip: string | null;
  network: NetworkConfig;
  cpus: number | null;
  memoryMB: number | null;
  diskGB: number | null;
  autostart: boolean;
  activity: string | null;
  backup: BackupPolicy;
  offsite: OffsitePolicy;
  cloudInit: CloudInit;
  seedPending: boolean;
  hasSeed: boolean;
  /** Image the VM was created from; null for VMs created by older versions. */
  image: string | null;
}

export interface Task {
  id: string;
  vm: string | null;
  title: string;
  status: 'running' | 'ok' | 'error';
  message: string | null;
  progress: number | null;
  started: string;
  finished: string | null;
}

export interface Host {
  hostname: string;
  tartVersion: string | null;
  cpus: number;
  memoryBytes: number;
  osVersion: string;
  diskFreeBytes: number;
  diskTotalBytes: number;
  web?: { bind: string; port: number; urls: WebURL[] };
}

export interface WebURL {
  url: string;
  address: string;
  device: string;
  name: string | null;
}

export interface Volume {
  path: string;
  name: string;
  fileSystem: string;
  internal: boolean;
  ejectable: boolean;
  freeBytes: number;
  totalBytes: number;
}

export interface StorageLocation {
  path: string;
  default: boolean;
  /** False while a custom location's drive is disconnected. */
  available: boolean;
  volume: Volume | null;
}

export type StorageKind = 'vms' | 'backups';

export interface StorageStatus {
  vms: StorageLocation;
  backups: StorageLocation;
  /** Which storage is being moved right now. */
  busy: StorageKind | null;
  /** VM storage is fixed by TART_HOME in the server's environment. */
  vmsFixed: boolean;
  /** Mounted external volumes. */
  volumes: Volume[];
}

export interface HostMemory {
  total: number;
  used: number;
  app: number;
  wired: number;
  compressed: number;
  cached: number;
  free: number;
  swapUsed: number;
  swapTotal: number;
  pressure: 'normal' | 'warning' | 'critical';
}

export interface HostStats {
  time: string;
  loadAverage: number[];
  runningVMs: number;
  vmMemoryBytes: number;
  memory?: HostMemory;
}

export interface Target {
  id: string;
  name: string;
  kind: 'smb' | 'pbs';
  location: string;
  keep: number;
  smb: { url: string } | null;
  pbs: {
    host: string;
    port: number;
    datastore: string;
    namespace: string | null;
    authId: string;
    fingerprint: string | null;
  } | null;
}

export interface NetInterface {
  device: string;
  name: string;
  default: boolean;
}

export interface Image {
  /** Catalog id, or the file name of an imported image. */
  id: string;
  name: string;
  /** null for imported images. */
  distro: string | null;
  /** Suggested cloud-init user. */
  user: string | null;
  /** Where the catalog image is downloaded from. */
  url: string | null;
  imported: boolean;
  cached: boolean;
  /** Virtual disk size: the smallest disk a VM from this image can have. */
  sizeBytes: number | null;
  /** Space the cached (sparse) image takes. */
  diskBytes: number | null;
  downloading: { message: string; progress: number | null } | null;
}

export interface Backup {
  id: string;
  date: string;
  consistent: boolean;
  source: string | null;
}

export interface Snapshot {
  vm: string;
  time: string;
  id: string;
}
