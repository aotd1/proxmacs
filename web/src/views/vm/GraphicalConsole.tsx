import RFB from '@novnc/novnc';
import { useEffect, useRef, useState } from 'react';
import { api, enc, errorMessage } from '../../api';
import { Badge } from '../../components/ui';
import type { VM } from '../../types';

export function GraphicalConsoleView({ vm }: { vm: VM }) {
  const host = useRef<HTMLDivElement>(null);
  const box = useRef<HTMLDivElement>(null);
  const client = useRef<RFB | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [status, setStatus] = useState('Connecting…');
  const [connected, setConnected] = useState(false);
  const [fit, setFit] = useState(true);
  const [viewOnly, setViewOnly] = useState(false);

  useEffect(() => {
    let disposed = false;
    let rfb: RFB | null = null;
    setConnected(false);
    if (vm.state !== 'running') {
      setStatus('The VM is not running. Start it to open the console.');
      return;
    }
    setStatus('Connecting…');
    void (async () => {
      try {
        const credentials = await api<{ password: string }>('POST', `/api/vms/${enc(vm.name)}/console/session`);
        if (disposed || !host.current) return;
        const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
        rfb = new RFB(host.current, `${scheme}//${location.host}/api/vms/${enc(vm.name)}/console/vnc`, { credentials, shared: true });
        client.current = rfb;
        rfb.scaleViewport = fit;
        rfb.viewOnly = viewOnly;
        rfb.resizeSession = false;
        rfb.focusOnClick = true;
        rfb.addEventListener('connect', () => {
          if (!disposed) { setConnected(true); setStatus('Connected'); }
        });
        rfb.addEventListener('disconnect', () => {
          if (!disposed) { setConnected(false); setStatus('Disconnected. Reconnect when the VM is ready.'); }
        });
        rfb.addEventListener('securityfailure', () => {
          if (!disposed) { setConnected(false); setStatus('Console authentication failed. Reconnect to refresh the session.'); }
        });
      } catch (error) {
        if (!disposed) setStatus(errorMessage(error));
      }
    })();
    return () => { disposed = true; rfb?.disconnect(); client.current = null; };
  }, [vm.name, vm.state, attempt]);

  useEffect(() => { if (client.current) client.current.scaleViewport = fit; }, [fit, connected]);
  useEffect(() => { if (client.current) client.current.viewOnly = viewOnly; }, [viewOnly, connected]);

  const commandSpace = () => {
    const rfb = client.current;
    if (!rfb) return;
    rfb.sendKey(0xffe7, 'MetaLeft', true);
    rfb.sendKey(0x20, 'Space', true);
    rfb.sendKey(0x20, 'Space', false);
    rfb.sendKey(0xffe7, 'MetaLeft', false);
    rfb.focus();
  };

  return <>
    <div className="console-toolbar">
      <Badge kind={connected ? 'ok' : 'warn'}>{connected ? 'Connected' : 'Disconnected'}</Badge>
      <label className="check"><input type="checkbox" checked={fit} onChange={(e) => setFit(e.target.checked)} />Fit screen</label>
      <label className="check"><input type="checkbox" checked={viewOnly} onChange={(e) => setViewOnly(e.target.checked)} />View only</label>
      <div className="spacer" />
      <button className="btn small" disabled={!connected || viewOnly} onClick={commandSpace}>⌘ Space</button>
      <button className="btn small" onClick={() => { void box.current?.requestFullscreen().catch(() => setStatus('Fullscreen is unavailable in this browser.')); }}>Fullscreen</button>
      <button className="btn small" onClick={() => setAttempt((n) => n + 1)}>Reconnect</button>
    </div>
    <div className="graphical-console" ref={box}>
      <div className="graphical-console-host" ref={host} />
      {!connected && <div className="term-overlay" role="status"><span>{status}</span></div>}
    </div>
  </>;
}
