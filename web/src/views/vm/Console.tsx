import { FitAddon } from '@xterm/addon-fit';
import { Terminal } from '@xterm/xterm';
import '@xterm/xterm/css/xterm.css';
import { useCallback, useEffect, useRef, useState } from 'react';
import { enc } from '../../api';
import { Badge } from '../../components/ui';
import type { VM } from '../../types';

type Status = { text: string; kind: '' | 'ok' | 'warn' | 'err' };

/** Serial console (hvc0) over a WebSocket bridged to the VM runner's console socket. */
export function ConsoleView({ vm }: { vm: VM }) {
  const hostRef = useRef<HTMLDivElement>(null);
  const boxRef = useRef<HTMLDivElement>(null);
  const termRef = useRef<Terminal | null>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const [status, setStatus] = useState<Status>({ text: 'Not connected', kind: '' });
  const [closeReason, setCloseReason] = useState<string | null>(null);
  const [disconnected, setDisconnected] = useState(false);
  const name = vm.name;

  const closeSocket = () => {
    const ws = wsRef.current;
    if (!ws) return;
    wsRef.current = null;
    ws.onopen = ws.onmessage = ws.onclose = ws.onerror = null;
    try { ws.close(); } catch { /* already closed */ }
  };

  const connect = useCallback(() => {
    const term = termRef.current;
    if (!term) return;
    closeSocket();
    setDisconnected(false);
    setStatus({ text: 'Connecting…', kind: 'warn' });
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    let ws: WebSocket;
    try {
      ws = new WebSocket(`${proto}//${location.host}/api/vms/${enc(name)}/console`);
    } catch (e) {
      setCloseReason(e instanceof Error ? e.message : String(e));
      setDisconnected(true);
      setStatus({ text: 'Disconnected', kind: 'err' });
      return;
    }
    ws.binaryType = 'arraybuffer';
    wsRef.current = ws;
    ws.onopen = () => {
      setStatus({ text: 'Connected', kind: 'ok' });
      term.focus();
    };
    ws.onmessage = (ev) => {
      if (typeof ev.data === 'string') term.write(ev.data);
      else term.write(new Uint8Array(ev.data as ArrayBuffer));
    };
    ws.onclose = (ev) => {
      if (wsRef.current !== ws) return;
      wsRef.current = null;
      setCloseReason(ev.reason || null);
      setDisconnected(true);
      setStatus({ text: 'Disconnected', kind: 'err' });
    };
  }, [name]);

  useEffect(() => {
    const host = hostRef.current, box = boxRef.current;
    if (!host || !box) return;
    const term = new Terminal({
      cursorBlink: true,
      scrollback: 5000,
      fontSize: 13,
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace',
      theme: { background: '#0c0c0c', foreground: '#e6e6e6', cursor: '#e6e6e6' },
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(host);
    termRef.current = term;
    const safeFit = () => {
      if (host.offsetWidth && host.offsetHeight) {
        try { fit.fit(); } catch { /* not laid out yet */ }
      }
    };
    const input = term.onData((data) => {
      if (wsRef.current?.readyState === WebSocket.OPEN) wsRef.current.send(data);
    });
    const observer = new ResizeObserver(safeFit);
    observer.observe(box);
    safeFit();
    connect();
    term.focus();
    return () => {
      closeSocket();
      observer.disconnect();
      input.dispose();
      term.dispose();
      termRef.current = null;
    };
  }, [connect]);

  const overlayText = vm.state !== 'running' ? `The VM is ${vm.state}. Start it, then reconnect.`
    : closeReason ?? 'The console connection was closed.';

  return (
    <>
      <div className="console-toolbar">
        <span className="muted">Serial console (hvc0). Press Enter for a login prompt.</span>
        <div className="spacer" />
        <Badge kind={status.kind}>{status.text}</Badge>
        <button type="button" className="btn small" onClick={connect}>Reconnect</button>
      </div>
      <div ref={boxRef} className="term-box">
        <div ref={hostRef} className="term-host" />
        {disconnected && (
          <div className="term-overlay">
            <strong>Disconnected</strong>
            <div className="small">{overlayText}</div>
            <button type="button" className="btn primary" onClick={connect}>Reconnect</button>
          </div>
        )}
      </div>
    </>
  );
}
