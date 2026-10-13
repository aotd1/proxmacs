import { lazy, Suspense, useEffect, useState, type ReactNode } from 'react';
import { fmtDate, fmtDuration, plural, timeFmt } from '../format';
import { routeHash, useHashRoute, type Route } from '../hooks';
import { useApp } from '../store';
import type { Task } from '../types';
import { CreateVMDialog } from '../views/CreateVM';
import { HostSummary } from '../views/host/HostSummary';
import { ImagesView } from '../views/host/Images';
import { TargetsView } from '../views/host/Targets';
import { BackupsView } from '../views/vm/Backups';
import { CloudInitView } from '../views/vm/CloudInit';
import { HardwareView } from '../views/vm/Hardware';
import { OffsiteView } from '../views/vm/Offsite';
import { VMSummary } from '../views/vm/Summary';
import { Badge, Loading, Spinner, StateBadge, StateDot } from './ui';

// xterm is large; load it with the console tab.
const ConsoleView = lazy(() => import('../views/vm/Console').then((m) => ({ default: m.ConsoleView })));

const HOST_TABS = [['summary', 'Summary'], ['targets', 'Backup Targets'], ['images', 'Images']] as const;
const VM_TABS = [
  ['summary', 'Summary'], ['hardware', 'Hardware'], ['cloudinit', 'Cloud-Init'],
  ['console', 'Console'], ['backups', 'Backups'], ['offsite', 'Offsite'],
] as const;

export type Navigate = (route: Route) => void;

export function Shell({ onLogout }: { onLogout: () => void }) {
  const app = useApp();
  const [rawRoute, navigate] = useHashRoute();
  const [creating, setCreating] = useState(false);

  // Fall back to the host when the VM is gone; unknown tabs show the summary.
  let route = rawRoute;
  if (route.type === 'vm' && app.loaded && !app.vm(route.name)) route = { type: 'host', tab: 'summary' };
  const tabs = route.type === 'vm' ? VM_TABS : HOST_TABS;
  if (!tabs.some(([id]) => id === route.tab)) route = { ...route, tab: 'summary' };
  useEffect(() => {
    const hash = routeHash(route);
    if (app.loaded && location.hash !== hash) history.replaceState(null, '', hash);
  });

  return (
    <div id="app">
      <Topbar onCreate={() => setCreating(true)} onLogout={onLogout} navigate={navigate} />
      <div className="main">
        <Tree route={route} navigate={navigate} />
        <section className="content">
          {app.loaded ? <Content route={route} navigate={navigate} /> : <Loading />}
        </section>
      </div>
      <TasksPanel />
      {creating && <CreateVMDialog onClose={() => setCreating(false)} />}
    </div>
  );
}

function Topbar({ onCreate, onLogout, navigate }: { onCreate: () => void; onLogout: () => void; navigate: Navigate }) {
  const { host, stats, tasks, online, setTasksOpen } = useApp();
  const running = tasks.filter((t) => t.status === 'running').length;
  const memory = stats?.memory;
  const usedPct = memory ? Math.round((memory.used / memory.total) * 100) : null;
  return (
    <header className="topbar">
      <div className="brand"><span className="brand-mark" aria-hidden="true" />Proxmacs</div>
      <div className="host-info">
        {host && <>
          <strong>{host.hostname || 'host'}</strong>
          <span>·</span>
          {host.tartVersion ? <span>Tart {host.tartVersion}</span>
            : <Badge kind="err" title="The tart binary was not found on this Mac">Tart not found</Badge>}
        </>}
      </div>
      <div className="spacer" />
      {memory && usedPct != null && (
        <button type="button" className={`mem-indicator ${memory.pressure}`} title={`Memory pressure: ${memory.pressure}`}
          onClick={() => navigate({ type: 'host', tab: 'summary' })}>
          <span>Memory</span>
          <span className="mini-meter"><span style={{ width: `${usedPct}%` }} /></span>
          <span className="mono">{usedPct}%</span>
        </button>
      )}
      {!online && <Badge kind="err">Connection lost</Badge>}
      <button type="button" className={`task-indicator${running ? ' active' : ''}`} title="Show task log" onClick={() => setTasksOpen(true)}>
        {running ? <><Spinner />{plural(running, 'task')} running</> : 'No running tasks'}
      </button>
      <button type="button" className="btn primary" onClick={onCreate}>Create VM</button>
      <button type="button" className="btn" onClick={onLogout}>Log out</button>
    </header>
  );
}

function Tree({ route, navigate }: { route: Route; navigate: Navigate }) {
  const { host, vms } = useApp();
  return (
    <nav className="tree-panel" aria-label="Resources">
      <ul className="tree" role="tree">
        <li role="treeitem" aria-expanded="true">
          <button type="button" className={`tree-item${route.type === 'host' ? ' selected' : ''}`}
            onClick={() => navigate({ type: 'host', tab: route.type === 'host' ? route.tab : 'summary' })}>
            <span className="host-icon" aria-hidden="true" />
            <span className="label">{host?.hostname || 'Host'}</span>
          </button>
          <ul role="group">
            {vms.length === 0 && <li className="tree-empty">No VMs</li>}
            {vms.map((vm) => {
              const selected = route.type === 'vm' && route.name === vm.name;
              return (
                <li key={vm.name} role="treeitem">
                  <button type="button" className={`tree-item${selected ? ' selected' : ''}`}
                    title={`${vm.name} — ${vm.state}${vm.activity ? ` (${vm.activity})` : ''}`}
                    onClick={() => navigate({ type: 'vm', name: vm.name, tab: route.type === 'vm' ? route.tab : 'summary' })}>
                    <StateDot state={vm.state} />
                    <span className="label">{vm.name}</span>
                    {vm.activity && <Spinner title={vm.activity} />}
                  </button>
                </li>
              );
            })}
          </ul>
        </li>
      </ul>
    </nav>
  );
}

function Content({ route, navigate }: { route: Route; navigate: Navigate }) {
  const app = useApp();
  const tabs = route.type === 'vm' ? VM_TABS : HOST_TABS;
  const vm = route.type === 'vm' ? app.vm(route.name) : null;
  const full = route.type === 'vm' && route.tab === 'console';

  let body: ReactNode = null;
  if (route.type === 'host') {
    body = route.tab === 'targets' ? <TargetsView /> : route.tab === 'images' ? <ImagesView /> : <HostSummary navigate={navigate} />;
  } else if (vm) {
    const props = { vm, navigate };
    body = {
      summary: <VMSummary {...props} />,
      hardware: <HardwareView {...props} />,
      cloudinit: <CloudInitView {...props} />,
      console: <Suspense fallback={<Loading />}><ConsoleView vm={vm} /></Suspense>,
      backups: <BackupsView vm={vm} />,
      offsite: <OffsiteView {...props} />,
    }[route.tab] ?? <VMSummary {...props} />;
  }

  return (
    <>
      <div className="content-header">
        {route.type === 'host'
          ? <h2><span className="kind">Host</span>{app.host?.hostname ?? ''}</h2>
          : <>
            <h2><span className="kind">VM</span>{route.name}</h2>
            {vm && <StateBadge state={vm.state} />}
            {vm?.activity && <Badge kind="info"><Spinner />{vm.activity}</Badge>}
            {vm?.seedPending && <Badge kind="warn" title="Cloud-init settings changed while running">restart to apply cloud-init</Badge>}
          </>}
      </div>
      <div className="tabbar" role="tablist">
        {tabs.map(([id, label]) => (
          <button key={id} type="button" role="tab" className={`tab${id === route.tab ? ' active' : ''}`} aria-selected={id === route.tab}
            onClick={() => navigate({ ...route, tab: id })}>
            {label}
          </button>
        ))}
      </div>
      {/* Keyed so each VM/tab gets fresh view state. */}
      <div key={routeHash(route)} className={`content-body${full ? ' full' : ''}`} role="tabpanel">
        <div className="view">{body}</div>
      </div>
    </>
  );
}

function TasksPanel() {
  const { tasks, tasksOpen, setTasksOpen } = useApp();
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const sorted = [...tasks].sort((a, b) => String(b.started).localeCompare(String(a.started)));
  const running = sorted.filter((t) => t.status === 'running').length;
  const errors = sorted.filter((t) => t.status === 'error').length;
  const toggle = (id: string) => setExpanded((s) => {
    const next = new Set(s);
    if (!next.delete(id)) next.add(id);
    return next;
  });

  return (
    <section className={`tasks-panel${tasksOpen ? '' : ' collapsed'}`}>
      <div className="tasks-header">
        <button type="button" className="tasks-toggle" aria-expanded={tasksOpen} onClick={() => setTasksOpen(!tasksOpen)}>
          <span className="chevron" aria-hidden="true" />Tasks
        </button>
        <span className="muted">
          {sorted.length ? `${sorted.length} total · ${running} running${errors ? ` · ${errors} failed` : ''}` : ''}
        </span>
      </div>
      <div className="tasks-body">
        {!sorted.length ? <div className="empty">No tasks yet.</div> : (
          <table className="table">
            <thead><tr><th>Started</th><th>VM</th><th>Task</th><th>Status</th><th>Message</th></tr></thead>
            <tbody>
              {sorted.map((t) => {
                const open = expanded.has(t.id);
                return [
                  <tr key={t.id} className={`task-row${open ? ' expanded' : ''}`} tabIndex={0} aria-expanded={open}
                    onClick={() => toggle(t.id)}
                    onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(t.id); } }}>
                    <td className="nowrap">{fmtDate(t.started, timeFmt)}</td>
                    <td className="nowrap">{t.vm || '—'}</td>
                    <td>
                      {t.title}
                      {t.status === 'running' && typeof t.progress === 'number' && (
                        <div className="progress"><div style={{ width: `${Math.round(Math.min(1, Math.max(0, t.progress)) * 100)}%` }} /></div>
                      )}
                    </td>
                    <td className="nowrap"><TaskStatus task={t} /></td>
                    <td className="task-msg" title={t.message ?? ''}>{t.message}</td>
                  </tr>,
                  open && (
                    <tr key={`${t.id}-detail`} className="task-detail">
                      <td colSpan={5}>
                        <div className="muted small">
                          Task {t.id} · started {fmtDate(t.started, timeFmt)}
                          {t.finished && ` · finished ${fmtDate(t.finished, timeFmt)} · took ${fmtDuration(t.started, t.finished)}`}
                        </div>
                        {t.message ? <pre>{t.message}</pre> : <div className="muted">No message.</div>}
                      </td>
                    </tr>
                  ),
                ];
              })}
            </tbody>
          </table>
        )}
      </div>
    </section>
  );
}

function TaskStatus({ task }: { task: Task }) {
  if (task.status === 'running') {
    const pct = typeof task.progress === 'number' ? ` ${Math.round(task.progress * 100)}%` : '';
    return <span className="task-status"><Spinner />running{pct}</span>;
  }
  if (task.status === 'ok') return <span className="task-status ok">OK</span>;
  if (task.status === 'error') return <span className="task-status error">Error</span>;
  return <span className="task-status">{task.status}</span>;
}
