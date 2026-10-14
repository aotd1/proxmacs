import { useCallback, useEffect, useState, type FormEvent } from 'react';
import { api, AuthError, enc, errorMessage } from '../../api';
import { Modal, useConfirm } from '../../components/Modal';
import { useToast } from '../../components/Toasts';
import { ActionButton, Badge, Empty, Field, KindBadge, Loading, Panel, Segmented, Spinner } from '../../components/ui';
import type { NotificationTarget } from '../../types';

type Format = NotificationTarget['format'];

const PRESETS: Record<Format, { label: string; placeholder: string; hint: string }> = {
  discord: {
    label: 'Discord', placeholder: 'https://discord.com/api/webhooks/…',
    hint: 'Channel settings → Integrations → Webhooks → New Webhook → Copy Webhook URL.',
  },
  slack: {
    label: 'Slack', placeholder: 'https://hooks.slack.com/services/…',
    hint: 'A Slack app with Incoming Webhooks turned on → Add New Webhook to Workspace → copy its URL.',
  },
  ntfy: {
    label: 'ntfy', placeholder: 'https://ntfy.sh/your-secret-topic',
    hint: 'A topic URL on ntfy.sh or your own ntfy server. Anyone who knows a public topic name can read it: pick a long random one.',
  },
  json: {
    label: 'JSON', placeholder: 'https://example.com/hook',
    hint: 'POSTs {"title", "message", "severity", "host", "source"} as JSON (Home Assistant, n8n, Gotify proxies…).',
  },
};

type Result = { state: 'testing' } | { state: 'ok' | 'fail'; message: string };

export function NotificationsView() {
  const confirm = useConfirm();
  const { toast } = useToast();
  const [targets, setTargets] = useState<NotificationTarget[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [results, setResults] = useState<Record<string, Result>>({});
  const [editing, setEditing] = useState<NotificationTarget | 'new' | null>(null);

  const load = useCallback(async () => {
    try {
      setTargets(await api<NotificationTarget[]>('GET', '/api/notifications'));
      setError(null);
    } catch (e) {
      if (!(e instanceof AuthError)) setError(errorMessage(e));
    }
  }, []);
  useEffect(() => { void load(); }, [load]);

  const test = async (t: NotificationTarget) => {
    setResults((r) => ({ ...r, [t.id]: { state: 'testing' } }));
    let result: Result;
    try {
      const r = await api<{ ok: boolean; message: string }>('POST', `/api/notifications/${enc(t.id)}/test`, {});
      result = { state: r.ok ? 'ok' : 'fail', message: r.message };
    } catch (e) {
      if (e instanceof AuthError) return;
      result = { state: 'fail', message: errorMessage(e) };
    }
    setResults((r) => ({ ...r, [t.id]: result }));
  };
  const toggle = async (t: NotificationTarget, enabled: boolean) => {
    await api('PUT', `/api/notifications/${enc(t.id)}`, { enabled });
    await load();
  };
  const remove = async (t: NotificationTarget) => {
    const ok = await confirm({ title: 'Delete webhook', message: `Delete the notification webhook “${t.name}”?`, confirmLabel: 'Delete', danger: true });
    if (!ok) return;
    await api('DELETE', `/api/notifications/${enc(t.id)}`, {});
    toast(`Webhook “${t.name}” deleted`, 'ok');
    await load();
  };

  return (
    <>
      <Panel title="Notification webhooks" flush extra={<button type="button" className="btn primary small" onClick={() => setEditing('new')}>Add webhook</button>}>
        {error ? <Empty error>{error}</Empty> : !targets ? <Loading /> : !targets.length
          ? <Empty>No webhooks. Add Discord, Slack or ntfy to hear about backup jobs.</Empty> : (
            <table className="table">
              <thead><tr><th>On</th><th>Name</th><th>Kind</th><th className="wide-only">Host</th><th>Test</th><th /></tr></thead>
              <tbody>
                {targets.map((t) => {
                  const r = results[t.id];
                  return (
                    <tr key={t.id}>
                      <td><input type="checkbox" className="switch" checked={t.enabled} aria-label={`Enable ${t.name}`}
                        onChange={(e) => void toggle(t, e.target.checked)} /></td>
                      <td><strong>{t.name}</strong></td>
                      <td><KindBadge kind={PRESETS[t.format].label} /></td>
                      <td className="wide-only mono wrap">{t.host}</td>
                      <td>
                        {!r ? <span className="muted">—</span>
                          : r.state === 'testing' ? <span className="task-status"><Spinner />sending…</span>
                            : <Badge kind={r.state === 'ok' ? 'ok' : 'err'} title={r.message}>{r.state === 'ok' ? 'Sent' : 'Failed'}</Badge>}
                        {r && r.state === 'fail' && <div className="small muted wrap">{r.message}</div>}
                      </td>
                      <td className="actions-cell">
                        <div className="actions">
                          <ActionButton className="small" onClick={() => test(t)}>Test</ActionButton>
                          <button type="button" className="btn small" onClick={() => setEditing(t)}>Edit</button>
                          <ActionButton className="small danger" onClick={() => remove(t)}>Delete</ActionButton>
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
      </Panel>
      <p className="muted small prose">
        Backup jobs post to every enabled webhook when they fail, or after every run, as set on each job. Webhook URLs contain
        their access token, so they are stored in the owner-only secrets file and never shown again.
      </p>
      {editing && <WebhookDialog target={editing === 'new' ? null : editing} onClose={() => setEditing(null)} onSaved={load} />}
    </>
  );
}

function WebhookDialog({ target, onClose, onSaved }: { target: NotificationTarget | null; onClose: () => void; onSaved: () => Promise<void> }) {
  const { toast, report } = useToast();
  const [format, setFormat] = useState<Format>(target?.format ?? 'discord');
  const [name, setName] = useState(target?.name ?? '');
  const [url, setURL] = useState('');
  const [busy, setBusy] = useState(false);
  const preset = PRESETS[format];

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    try {
      const body = { name: name.trim() || preset.label, format, url: url.trim() || undefined };
      await api(target ? 'PUT' : 'POST', target ? `/api/notifications/${enc(target.id)}` : '/api/notifications', body);
      toast(target ? 'Webhook saved' : 'Webhook added: use Test to check it', 'ok');
      await onSaved();
      onClose();
    } catch (err) {
      report(err);
      setBusy(false);
    }
  };

  return (
    <Modal title={target ? `Edit ${target.name}` : 'Add notification webhook'} onClose={onClose}>
      <form onSubmit={submit} autoComplete="off">
        <div className="modal-body stack">
          <div className="field">
            <span>Service</span>
            <Segmented name="format" value={format} onChange={setFormat}
              options={(Object.keys(PRESETS) as Format[]).map((f) => [f, PRESETS[f].label])} />
          </div>
          <Field label="Name"><input type="text" maxLength={64} placeholder={preset.label} value={name} onChange={(e) => setName(e.target.value)} /></Field>
          <Field label="Webhook URL" hint={target ? `Leave empty to keep the stored URL (${target.host}). ${preset.hint}` : preset.hint}>
            <input type="url" required={!target} placeholder={preset.placeholder} spellCheck={false} value={url}
              onChange={(e) => setURL(e.target.value)} />
          </Field>
        </div>
        <div className="modal-footer">
          <button type="button" className="btn" onClick={onClose}>Cancel</button>
          <button type="submit" className="btn primary" disabled={busy}>{busy && <Spinner />}{target ? 'Save' : 'Add webhook'}</button>
        </div>
      </form>
    </Modal>
  );
}
