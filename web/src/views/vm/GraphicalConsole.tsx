import RFB from '@novnc/novnc';
import { useEffect, useRef, useState } from 'react';
import { api, enc, errorMessage } from '../../api';
import { Badge } from '../../components/ui';
import type { VM } from '../../types';
import { textKeys, typeKeys } from './consoleText';

// Keep pinned noVNC's default warning-only logging: info/debug includes password keysyms.

export function GraphicalConsoleView({ vm }: { vm: VM }) {
  const host = useRef<HTMLDivElement>(null);
  const box = useRef<HTMLDivElement>(null);
  const dialog = useRef<HTMLDialogElement>(null);
  const pasteButton = useRef<HTMLButtonElement>(null);
  const client = useRef<RFB | null>(null);
  const transfer = useRef<AbortController | null>(null);
  const clipboardRequest = useRef(0);
  const generation = useRef(0);
  const [attempt, setAttempt] = useState(0);
  const [status, setStatus] = useState('Connecting…');
  const [connected, setConnected] = useState(false);
  const [fit, setFit] = useState(true);
  const [viewOnly, setViewOnly] = useState(false);
  const [fullscreen, setFullscreen] = useState(false);
  const [focused, setFocused] = useState(false);
  const [text, setText] = useState('');
  const [shown, setShown] = useState(false);
  const [controls, setControls] = useState(false);
  const [pasteHint, setPasteHint] = useState('');
  const [notice, setNotice] = useState('');
  const [sending, setSending] = useState(false);
  const [progress, setProgress] = useState({ sent: 0, total: 0 });

  const clearDraft = () => {
    clipboardRequest.current++;
    setText(''); setShown(false); setControls(false); setPasteHint('');
  };
  const closePaste = () => { dialog.current?.close(); clearDraft(); };
  const interrupt = () => {
    transfer.current?.abort();
    transfer.current = null;
    clipboardRequest.current++;
  };

  useEffect(() => {
    let disposed = false;
    let rfb: RFB | null = null;
    generation.current++;
    setConnected(false); setFocused(false); setSending(false); setNotice(''); closePaste();
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
        rfb.scaleViewport = fit; rfb.viewOnly = viewOnly; rfb.resizeSession = false; rfb.focusOnClick = true;
        rfb.addEventListener('connect', () => {
          if (!disposed) { setConnected(true); setStatus('Connected'); }
        });
        rfb.addEventListener('disconnect', () => {
          if (!disposed) {
            interrupt(); closePaste(); setConnected(false); setFocused(false);
            setStatus('Connection lost. Reconnect when the VM is ready.');
          }
        });
        rfb.addEventListener('securityfailure', () => {
          if (!disposed) {
            interrupt(); closePaste(); setConnected(false);
            setStatus('Console authentication failed. Reconnect to refresh the session.');
          }
        });
      } catch (error) { if (!disposed) setStatus(errorMessage(error)); }
    })();
    return () => { disposed = true; generation.current++; interrupt(); rfb?.disconnect(); client.current = null; };
  }, [vm.name, vm.state, attempt]);

  useEffect(() => { if (client.current) client.current.scaleViewport = fit; }, [fit, connected]);
  useEffect(() => {
    if (viewOnly) { interrupt(); closePaste(); }
    if (client.current) client.current.viewOnly = viewOnly;
  }, [viewOnly, connected]);
  useEffect(() => {
    const change = () => setFullscreen(document.fullscreenElement === box.current);
    const suspend = () => { interrupt(); closePaste(); };
    const visibility = () => { if (document.hidden) suspend(); };
    const blur = () => { transfer.current?.abort(); };
    document.addEventListener('fullscreenchange', change);
    document.addEventListener('visibilitychange', visibility);
    window.addEventListener('blur', blur);
    return () => {
      document.removeEventListener('fullscreenchange', change);
      document.removeEventListener('visibilitychange', visibility);
      window.removeEventListener('blur', blur);
    };
  }, []);

  const openPaste = async () => {
    if (!connected || viewOnly || transfer.current) return;
    clearDraft(); setNotice(''); dialog.current?.showModal();
    const request = clipboardRequest.current;
    try {
      const value = await navigator.clipboard.readText();
      if (clipboardRequest.current !== request || !dialog.current?.open) return;
      if (value.length > 16384) { setPasteHint('Clipboard is too large. Paste up to 4,096 characters.'); return; }
      setText(value);
      setPasteHint(value ? '' : 'Clipboard is empty. Paste or type text below.');
    } catch {
      if (clipboardRequest.current === request && dialog.current?.open) setPasteHint('Paste here with ⌘V on Mac, or Ctrl+V.');
    }
  };

  const sendText = async () => {
    const rfb = client.current;
    if (!rfb || !connected || viewOnly || transfer.current) return;
    let keys: number[];
    try { keys = textKeys(text, controls); }
    catch (error) { setPasteHint(errorMessage(error)); return; }
    const run = generation.current;
    const controller = new AbortController();
    transfer.current = controller;
    closePaste(); setSending(true); setProgress({ sent: 0, total: keys.length }); setNotice('');
    // Keep the browser focus on Stop, so physical keys cannot mix with the text queue.
    let sent = 0;
    try {
      sent = await typeKeys(keys, (key, down) => rfb.sendKey(key, undefined, down), controller.signal,
        count => { sent = count; if (generation.current === run) setProgress({ sent: count, total: keys.length }); });
      if (generation.current === run) setNotice(controller.signal.aborted
        ? `Stopped after ${sent} of ${keys.length} characters. Already sent text is not erased.` : 'Text sent.');
    } catch {
      if (generation.current === run) setNotice(`Text interrupted after ${sent} characters. Check the VM before retrying.`);
    } finally {
      keys.fill(0);
      if (transfer.current === controller) transfer.current = null;
      if (generation.current === run) { setSending(false); pasteButton.current?.focus(); }
    }
  };

  const toggleFullscreen = async () => {
    try {
      if (document.fullscreenElement === box.current) await document.exitFullscreen();
      else await box.current?.requestFullscreen();
    } catch { setNotice('Fullscreen is unavailable in this browser.'); }
  };
  const count = Array.from(text.replace(/\r\n?/g, '\n')).length;
  const special = /[\r\n\t]/.test(text);

  return <section className="console-workspace" ref={box} aria-label={`${vm.name} console`}>
    <div className="console-toolbar graphical-toolbar">
      <Badge kind={connected ? 'ok' : 'warn'}>{connected ? 'Connected' : vm.state !== 'running' ? 'Stopped' : status.startsWith('Connecting') ? 'Connecting…' : 'Disconnected'}</Badge>
      {fullscreen && <strong className="console-vm-label">{vm.name}</strong>}
      <button ref={pasteButton} className="btn small" disabled={!connected || viewOnly || sending} onClick={() => { void openPaste(); }}>Type clipboard…</button>
      <div className="spacer" />
      <select aria-label="Display scale" value={fit ? 'fit' : 'actual'} onChange={e => setFit(e.target.value === 'fit')}>
        <option value="fit">Fit screen</option><option value="actual">Actual size</option>
      </select>
      <button className="btn small" onClick={() => { void toggleFullscreen(); }}>{fullscreen ? 'Exit fullscreen' : 'Fullscreen'}</button>
      <details className="console-options" onBlur={e => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) e.currentTarget.open = false;
      }} onKeyDown={e => {
        if (e.key === 'Escape') { e.currentTarget.open = false; e.currentTarget.querySelector('summary')?.focus(); }
      }}>
        <summary className="btn small" aria-label="Console options">•••</summary>
        <div className="console-options-panel">
          <label className="check"><input type="checkbox" checked={viewOnly} onChange={e => setViewOnly(e.target.checked)} />View only</label>
          <button className="btn small" disabled={sending} onClick={e => { e.currentTarget.closest('details')?.removeAttribute('open'); setAttempt(n => n + 1); }}>Reconnect</button>
          <p>Click the VM to send keyboard input. System shortcuts may stay on your Mac. Use Type clipboard for local text.</p>
        </div>
      </details>
    </div>
    <div className="graphical-console">
      <div className="graphical-console-host" ref={host} onFocusCapture={() => setFocused(true)} onBlurCapture={() => setFocused(false)} />
      {sending && <div className="term-overlay console-transfer">
        <span>Sending {progress.sent} / {progress.total}</span>
        <progress aria-label="Typing progress" value={progress.sent} max={progress.total} />
        <button className="btn" autoFocus onClick={() => transfer.current?.abort()}>Stop typing</button>
      </div>}
      {!connected && <div className="term-overlay console-transfer" role="status"><span>{status}</span>
        {vm.state === 'running' && <button className="btn" onClick={() => setAttempt(n => n + 1)}>Reconnect</button>}
      </div>}
    </div>
    <div className="console-footer"><span>{viewOnly ? 'View only' : focused && connected ? 'Keyboard: VM' : 'Click the VM to use its keyboard'}</span><span role="status">{notice}</span></div>
    <dialog className="console-paste-dialog" ref={dialog} aria-labelledby="console-paste-title" onCancel={clearDraft} onClose={clearDraft}>
      <h3 id="console-paste-title">Type text in {vm.name}</h3>
      <p>First select the destination field in the VM. Text is typed there; Enter is not added.</p>
      <label htmlFor="console-text">Text to type</label>
      {shown ? <textarea id="console-text" rows={4} value={text} maxLength={16384} spellCheck={false} autoComplete="off" autoCapitalize="off" onChange={e => setText(e.target.value)} />
        : <input id="console-text" type="password" readOnly={special} value={text.replace(/[\r\n]/g, ' ')} maxLength={16384} autoComplete="off" spellCheck={false}
          onPaste={e => {
            e.preventDefault();
            const value = e.clipboardData.getData('text/plain');
            const start = e.currentTarget.selectionStart ?? text.length;
            const end = e.currentTarget.selectionEnd ?? start;
            setText((special ? value : text.slice(0, start) + value + text.slice(end)).slice(0, 16384));
          }} onChange={e => setText(e.target.value)} />}
      <div className="console-paste-meta"><span>{count} characters{special ? ' · includes line breaks or Tab' : ' · one line'}</span>
        <button className="btn small" onClick={() => setShown(value => !value)}>{shown ? 'Hide' : 'Show'}</button>
      </div>
      {special && <label className="check"><input type="checkbox" checked={controls} onChange={e => setControls(e.target.checked)} />Allow line breaks and Tab (may submit forms or move focus)</label>}
      {special && !shown && <p>Choose Show to edit multiline text.</p>}
      {pasteHint && <p role="alert">{pasteHint}</p>}
      <div className="console-paste-actions"><button className="btn" onClick={closePaste}>Cancel</button>
        <button className="btn primary" disabled={!text || count > 4096 || (special && !controls) || !connected || viewOnly} onClick={() => { void sendText(); }}>Type in VM</button>
      </div>
    </dialog>
  </section>;
}
