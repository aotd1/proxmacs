/* Proxmacs web UI — plain ES2020, no build step. */
'use strict';

(() => {
  // ================================================================
  // Small helpers
  // ================================================================

  const $ = (sel, root = document) => root.querySelector(sel);
  const enc = encodeURIComponent;

  // Properties assigned directly instead of via setAttribute.
  const PROPS = new Set(['checked', 'disabled', 'selected', 'hidden', 'readOnly', 'required', 'multiple', 'indeterminate']);

  /** Tiny element builder. Children may be nodes, strings, numbers, arrays, null/false. Strings are always text. */
  function h(tag, attrs, ...children) {
    const el = document.createElement(tag);
    let value;
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (v == null || v === false) continue;
        if (k === 'class') el.className = v;
        else if (k === 'style') el.style.cssText = v; // CSSOM, not an inline style attribute (CSP friendly)
        else if (k === 'value') value = v; // applied after children (needed for <select>)
        else if (k === 'dataset') Object.assign(el.dataset, v);
        else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v);
        else if (PROPS.has(k)) el[k] = v;
        else el.setAttribute(k, v === true ? '' : String(v));
      }
    }
    appendChildren(el, children);
    if (value !== undefined) el.value = value;
    return el;
  }

  function appendChildren(el, children) {
    for (const c of children.flat(Infinity)) {
      if (c == null || c === false) continue;
      el.append(c instanceof Node ? c : document.createTextNode(String(c)));
    }
  }

  /** Rebuild el's children only when the signature changed (avoids DOM churn on polling). */
  function renderIfChanged(el, sig, build) {
    if (el._sig === sig) return false;
    el._sig = sig;
    const out = build();
    el.replaceChildren();
    appendChildren(el, [out]);
    return true;
  }

  const pad2 = (n) => String(n).padStart(2, '0');

  function fmtBytes(b) {
    if (b == null || !isFinite(b)) return '—';
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    let i = 0;
    while (Math.abs(b) >= 1024 && i < units.length - 1) { b /= 1024; i++; }
    return `${b.toFixed(i >= 3 ? 1 : 0)} ${units[i]}`;
  }

  function fmtMemMB(mb) {
    if (mb == null) return '—';
    if (mb >= 1024) {
      const gb = mb / 1024;
      return `${Number.isInteger(gb) ? gb : gb.toFixed(1)} GB`;
    }
    return `${mb} MB`;
  }

  const dateFmt = new Intl.DateTimeFormat(undefined, { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  const timeFmt = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' });

  function fmtDate(iso, fmt = dateFmt) {
    if (!iso) return '—';
    const d = new Date(iso);
    return isNaN(d) ? String(iso) : fmt.format(d);
  }

  function fmtDuration(startIso, endIso) {
    const s = new Date(startIso), e = endIso ? new Date(endIso) : new Date();
    if (isNaN(s) || isNaN(e)) return '';
    let sec = Math.max(0, Math.round((e - s) / 1000));
    const hrs = Math.floor(sec / 3600); sec %= 3600;
    const min = Math.floor(sec / 60); sec %= 60;
    if (hrs) return `${hrs}h ${min}m`;
    if (min) return `${min}m ${sec}s`;
    return `${sec}s`;
  }

  function stateClass(st) {
    return st === 'running' || st === 'stopped' || st === 'missing' ? st : 'other';
  }
  function stateBadgeClass(st) {
    return { running: 'ok', stopped: '', missing: 'err' }[st] ?? 'warn';
  }
  const stateDot = (st) => h('span', { class: `dot ${stateClass(st)}`, title: st });
  const stateBadge = (st) => h('span', { class: `badge ${stateBadgeClass(st)}` }, st || 'unknown');

  function lsGet(key, fallback) {
    try { const v = localStorage.getItem(key); return v == null ? fallback : JSON.parse(v); } catch { return fallback; }
  }
  function lsSet(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* ignore */ }
  }

  async function copyText(text) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
        return true;
      }
    } catch { /* fall through */ }
    const ta = h('textarea', { style: 'position:fixed;left:-9999px;top:0', readonly: true });
    ta.value = text;
    document.body.append(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch { ok = false; }
    ta.remove();
    return ok;
  }

  // ================================================================
  // API
  // ================================================================

  class AuthError extends Error { constructor() { super('Not authenticated'); } }
  class ApiError extends Error { constructor(msg, status) { super(msg); this.status = status; } }

  async function api(method, path, body) {
    const opts = { method, headers: { Accept: 'application/json' }, credentials: 'same-origin', cache: 'no-store' };
    if (method !== 'GET' && method !== 'HEAD') {
      // The server uses this header as CSRF protection: always send it, with a body.
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(body ?? {});
    }
    let res;
    try {
      res = await fetch(path, opts);
    } catch (e) {
      throw new ApiError('Cannot reach the Proxmacs server', 0);
    }
    if (res.status === 401) {
      showLogin();
      throw new AuthError();
    }
    const text = await res.text();
    let data = null;
    if (text) { try { data = JSON.parse(text); } catch { data = text; } }
    if (!res.ok) {
      const msg = (data && typeof data === 'object' && data.error) || (typeof data === 'string' && data.length < 300 && data) || `Request failed (HTTP ${res.status})`;
      throw new ApiError(String(msg), res.status);
    }
    return data;
  }

  function reportError(e) {
    if (e instanceof AuthError) return;
    console.error(e);
    toast(e && e.message ? e.message : String(e), 'error');
  }

  /** Runs an action from a button: disables it while running, toasts errors. */
  async function busy(btn, fn) {
    if (btn) btn.disabled = true;
    try { return await fn(); } catch (e) { reportError(e); return undefined; } finally { if (btn && btn.isConnected) btn.disabled = false; }
  }

  /** Starts a backend task (202 {task}) and tracks it so the user is notified on completion. */
  async function startTask(method, path, body, label) {
    const r = await api(method, path, body);
    if (r && r.task != null) state.myTasks.set(String(r.task), label);
    toast(r && r.message ? r.message : `${label}: started`, 'info');
    pollNow();
    return r;
  }

  // ================================================================
  // State
  // ================================================================

  const TABS = {
    host: [['summary', 'Summary'], ['targets', 'Backup Targets'], ['images', 'Images']],
    vm: [['summary', 'Summary'], ['console', 'Console'], ['backups', 'Backups'], ['offsite', 'Offsite']],
  };

  const state = {
    authed: false,
    loaded: false,
    host: null,
    vms: [],
    tasks: [],
    targets: [],
    interfaces: [],
    sel: { type: 'host', name: null },
    tabs: { host: 'summary', vm: 'summary' },
    expandedTasks: new Set(),
    myTasks: new Map(),      // task id -> label (tasks started from this page)
    taskStatus: new Map(),   // task id -> last seen status
    tasksSeeded: false,
    tasksOpen: lsGet('proxmacs.tasksOpen', true),
    online: true,
  };

  const vmByName = (name) => state.vms.find((v) => v.name === name) || null;
  const targetById = (id) => state.targets.find((t) => String(t.id) === String(id)) || null;

  function updateVm(vm) {
    if (!vm || !vm.name) return;
    const i = state.vms.findIndex((v) => v.name === vm.name);
    if (i >= 0) state.vms[i] = vm; else state.vms.push(vm);
    renderAll();
  }

  // ================================================================
  // Polling
  // ================================================================

  function makePoller(fn, ms) {
    let timer = null, stopped = false, running = false, again = false;
    async function tick() {
      clearTimeout(timer); timer = null;
      if (stopped) return;
      if (running) { again = true; return; }
      if (document.visibilityState === 'visible') {
        running = true;
        try { await fn(); } catch (e) { /* handled inside fn */ }
        running = false;
        if (again && !stopped) { again = false; tick(); return; }
      }
      if (!stopped) timer = setTimeout(tick, ms);
    }
    timer = setTimeout(tick, ms);
    return { stop() { stopped = true; clearTimeout(timer); }, now: tick };
  }

  let fastPoller = null, slowPoller = null;

  function startPolling() {
    stopPolling();
    fastPoller = makePoller(refreshFast, 3000);
    slowPoller = makePoller(refreshSlow, 15000);
  }
  function stopPolling() {
    fastPoller?.stop(); slowPoller?.stop();
    fastPoller = slowPoller = null;
  }
  function pollNow() { fastPoller?.now(); }

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && state.authed) { fastPoller?.now(); slowPoller?.now(); }
  });

  function setOnline(ok) {
    if (state.online === ok) return;
    state.online = ok;
    $('#conn-status').hidden = ok;
  }

  async function refreshFast() {
    try {
      const [vms, tasks] = await Promise.all([api('GET', '/api/vms'), api('GET', '/api/tasks')]);
      if (!state.authed) return;
      setOnline(true);
      state.vms = (Array.isArray(vms) ? vms : []).slice().sort((a, b) => a.name.localeCompare(b.name));
      const finished = handleTasks(Array.isArray(tasks) ? tasks : []);
      renderAll();
      if (finished.length) {
        for (const t of finished) cur?.view.onTaskFinished?.(t);
        // VM state likely changed with the task — refresh once more soon.
        setTimeout(pollNow, 300);
      }
    } catch (e) {
      if (!(e instanceof AuthError)) setOnline(false);
    }
  }

  async function refreshSlow() {
    await Promise.all([loadHost(), loadTargets()]);
  }

  async function loadHost() {
    try {
      state.host = await api('GET', '/api/host');
      renderTopbar(); renderTree(); cur?.view.update?.();
    } catch (e) { /* topbar keeps old info */ }
  }

  async function loadTargets() {
    try {
      const t = await api('GET', '/api/targets');
      state.targets = Array.isArray(t) ? t : [];
      cur?.view.update?.();
    } catch (e) { if (!(e instanceof AuthError)) console.warn('targets:', e.message); }
  }

  async function loadInterfaces() {
    try {
      const i = await api('GET', '/api/interfaces');
      state.interfaces = Array.isArray(i) ? i : [];
    } catch (e) { /* optional */ }
  }

  /** Updates task list and returns tasks that just finished. */
  function handleTasks(tasks) {
    const finished = [];
    for (const t of tasks) {
      const id = String(t.id);
      const prev = state.taskStatus.get(id);
      if (state.tasksSeeded && t.status !== 'running' && (prev === 'running' || prev === undefined)) finished.push(t);
      state.taskStatus.set(id, t.status);
    }
    state.tasksSeeded = true;
    state.tasks = tasks;
    for (const t of finished) {
      const id = String(t.id);
      if (state.myTasks.has(id)) {
        const label = t.title || state.myTasks.get(id);
        state.myTasks.delete(id);
        if (t.status === 'ok') toast(`${label}: done${t.message ? ` — ${t.message}` : ''}`, 'ok');
        else toast(`${label}: failed${t.message ? ` — ${t.message}` : ''}`, 'error');
      }
    }
    return finished;
  }

  // ================================================================
  // Toasts & modals
  // ================================================================

  function toast(msg, kind = 'error') {
    const t = h('div', { class: `toast ${kind}`, role: kind === 'error' ? 'alert' : 'status', title: 'Click to dismiss' }, msg);
    t.addEventListener('click', () => t.remove());
    $('#toasts').append(t);
    while ($('#toasts').children.length > 6) $('#toasts').firstElementChild.remove();
    setTimeout(() => t.remove(), kind === 'error' ? 10000 : 5000);
  }

  let modalStack = [];

  function openModal({ title, content, onClose, wide }) {
    const backdrop = h('div', { class: 'modal-backdrop' });
    const m = { close };
    const dlg = h('div', { class: 'modal', role: 'dialog', 'aria-modal': 'true', 'aria-label': title, style: wide ? 'width:680px' : null },
      h('div', { class: 'modal-header' },
        h('h2', {}, title),
        h('button', { type: 'button', class: 'icon-btn', 'aria-label': 'Close', onclick: () => close() }, '×')),
      content);
    backdrop.append(dlg);
    $('#modal-root').append(backdrop);
    modalStack.push(m);
    function close() {
      if (!backdrop.isConnected) return;
      backdrop.remove();
      modalStack = modalStack.filter((x) => x !== m);
      onClose?.();
    }
    setTimeout(() => {
      const f = dlg.querySelector('[autofocus]') || dlg.querySelector('input:not([type=hidden]):not(:disabled), select, .modal-footer .primary');
      f?.focus();
    });
    m.el = dlg;
    return m;
  }

  function closeAllModals() { for (const m of modalStack.slice()) m.close(); }

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && modalStack.length) {
      e.preventDefault();
      modalStack[modalStack.length - 1].close();
    }
  });

  function confirmDialog({ title, message, confirmLabel = 'OK', danger = false, requireText = null }) {
    return new Promise((resolve) => {
      let done = false;
      const input = requireText != null
        ? h('input', { type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', autofocus: true })
        : null;
      const okBtn = h('button', { type: 'submit', class: danger ? 'btn danger solid' : 'btn primary', disabled: requireText != null }, confirmLabel);
      if (input) input.addEventListener('input', () => { okBtn.disabled = input.value !== requireText; });
      const form = h('form', {
        onsubmit: (e) => {
          e.preventDefault();
          if (okBtn.disabled) return;
          done = true; resolve(true); m.close();
        },
      },
      h('div', { class: 'modal-body' },
        h('p', {}, message),
        input ? h('label', { class: 'field' }, h('span', {}, 'Type ', h('strong', {}, requireText), ' to confirm'), input) : null),
      h('div', { class: 'modal-footer' },
        h('button', { type: 'button', class: 'btn', onclick: () => m.close() }, 'Cancel'),
        okBtn));
      const m = openModal({ title, content: form, onClose: () => { if (!done) resolve(false); } });
      if (!input) setTimeout(() => okBtn.focus());
    });
  }

  // ================================================================
  // Login / session
  // ================================================================

  function showLogin(message) {
    const wasAuthed = state.authed;
    state.authed = false;
    stopPolling();
    destroyView();
    closeAllModals();
    $('#boot').hidden = true;
    $('#app').hidden = true;
    const login = $('#login');
    if (wasAuthed || login.hidden) {
      login.hidden = false;
      $('#login-password').value = '';
    }
    $('#login-error').textContent = message || '';
    $('#login-password').focus();
  }

  async function enterApp() {
    state.authed = true;
    state.loaded = false;
    state.tasksSeeded = false;
    state.taskStatus.clear();
    $('#boot').hidden = true;
    $('#login').hidden = true;
    $('#app').hidden = false;
    for (const id of ['tree', 'tasks-body', 'host-info', 'task-indicator']) $('#' + id)._sig = undefined;
    applyTasksOpen();
    await Promise.all([refreshFast(), loadHost(), loadTargets(), loadInterfaces()]);
    if (!state.authed) return;
    state.loaded = true;
    applyHash();
    renderAll();
    startPolling();
  }

  async function boot() {
    $('#login-form').addEventListener('submit', onLoginSubmit);
    $('#logout').addEventListener('click', async () => {
      try { await api('POST', '/api/logout', {}); } catch (e) { if (!(e instanceof AuthError)) reportError(e); }
      showLogin();
    });
    $('#create-vm').addEventListener('click', () => openCreateVm());
    $('#task-indicator').addEventListener('click', () => { state.tasksOpen = true; applyTasksOpen(); });
    $('#tasks-toggle').addEventListener('click', () => { state.tasksOpen = !state.tasksOpen; applyTasksOpen(); });
    window.addEventListener('hashchange', () => { if (state.loaded) { applyHash(); renderAll(); } });

    try {
      const s = await api('GET', '/api/session');
      if (s && s.authenticated) await enterApp();
      else showLogin();
    } catch (e) {
      if (!(e instanceof AuthError)) showLogin(e.message);
    }
  }

  async function onLoginSubmit(e) {
    e.preventDefault();
    const pw = $('#login-password'), btn = $('#login-submit'), err = $('#login-error');
    btn.disabled = true;
    err.textContent = '';
    try {
      const res = await fetch('/api/login', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({ password: pw.value }),
      });
      if (res.status === 401) {
        err.textContent = 'Wrong password';
        pw.select();
        return;
      }
      if (!res.ok) {
        let msg = `Login failed (HTTP ${res.status})`;
        try { const j = await res.json(); if (j && j.error) msg = j.error; } catch { /* ignore */ }
        err.textContent = msg;
        return;
      }
      pw.value = '';
      await enterApp();
    } catch {
      err.textContent = 'Cannot reach the Proxmacs server';
    } finally {
      btn.disabled = false;
    }
  }

  // ================================================================
  // Selection & routing (#/host/<tab>, #/vm/<name>/<tab>)
  // ================================================================

  function updateHash() {
    const s = state.sel, tab = state.tabs[s.type];
    const hash = s.type === 'vm' ? `#/vm/${enc(s.name)}/${tab}` : `#/host/${tab}`;
    if (location.hash !== hash) history.replaceState(null, '', hash);
  }

  function applyHash() {
    const parts = location.hash.replace(/^#\/?/, '').split('/');
    const validTab = (type, t) => TABS[type].some(([id]) => id === t);
    if (parts[0] === 'vm' && parts[1]) {
      let name;
      try { name = decodeURIComponent(parts[1]); } catch { name = null; }
      if (name && vmByName(name)) {
        state.sel = { type: 'vm', name };
        if (validTab('vm', parts[2])) state.tabs.vm = parts[2];
        return;
      }
    } else if (parts[0] === 'host') {
      state.sel = { type: 'host', name: null };
      if (validTab('host', parts[1])) state.tabs.host = parts[1];
      return;
    }
    state.sel = { type: 'host', name: null };
    updateHash();
  }

  function select(type, name = null, tab = null) {
    state.sel = { type, name };
    if (tab) state.tabs[type] = tab;
    updateHash();
    renderAll();
  }

  function selectTab(tab) {
    state.tabs[state.sel.type] = tab;
    updateHash();
    renderContent();
  }

  // ================================================================
  // Rendering: shell
  // ================================================================

  function renderAll() {
    if (!state.authed) return;
    renderTopbar();
    renderTree();
    renderContent();
    renderTasks();
  }

  function renderTopbar() {
    const host = state.host;
    renderIfChanged($('#host-info'), JSON.stringify([host?.hostname, host?.tartVersion]), () => host ? [
      h('strong', {}, host.hostname || 'host'),
      h('span', {}, '·'),
      host.tartVersion
        ? h('span', {}, `Tart ${host.tartVersion}`)
        : h('span', { class: 'badge err', title: 'The tart binary was not found on this Mac' }, 'Tart not found'),
    ] : null);

    const running = state.tasks.filter((t) => t.status === 'running').length;
    const ind = $('#task-indicator');
    ind.classList.toggle('active', running > 0);
    renderIfChanged(ind, String(running), () => running
      ? [h('span', { class: 'spinner' }), `${running} task${running === 1 ? '' : 's'} running`]
      : 'No running tasks');
  }

  function renderTree() {
    const tree = $('#tree');
    const sig = JSON.stringify([state.host?.hostname, state.vms.map((v) => [v.name, v.state, v.activity]), state.sel]);
    renderIfChanged(tree, sig, () => {
      const hostSel = state.sel.type === 'host';
      return h('ul', { class: 'tree', role: 'tree' },
        h('li', { role: 'treeitem', 'aria-expanded': 'true' },
          h('button', { type: 'button', class: `tree-item${hostSel ? ' selected' : ''}`, onclick: () => select('host') },
            h('span', { class: 'host-icon', 'aria-hidden': 'true' }),
            h('span', { class: 'label' }, state.host?.hostname || 'Host')),
          h('ul', { role: 'group' },
            state.vms.length === 0 ? h('li', { class: 'tree-empty' }, 'No VMs') : null,
            state.vms.map((vm) => {
              const sel = state.sel.type === 'vm' && state.sel.name === vm.name;
              return h('li', { role: 'treeitem' },
                h('button', {
                  type: 'button', class: `tree-item${sel ? ' selected' : ''}`,
                  title: `${vm.name} — ${vm.state}${vm.activity ? ` (${vm.activity})` : ''}`,
                  onclick: () => select('vm', vm.name),
                },
                stateDot(vm.state),
                h('span', { class: 'label' }, vm.name),
                vm.activity ? h('span', { class: 'spinner', title: vm.activity }) : null));
            }))));
    });
  }

  let cur = null; // { key, view, header }

  function destroyView() {
    if (cur) {
      try { cur.view.destroy?.(); } catch (e) { console.error(e); }
      cur = null;
    }
  }

  function renderContent() {
    if (!state.authed || !state.loaded) return;
    const content = $('#content');
    let sel = state.sel;
    if (sel.type === 'vm' && state.loaded && !vmByName(sel.name)) {
      state.sel = sel = { type: 'host', name: null };
      updateHash();
    }
    const tab = state.tabs[sel.type];
    const key = `${sel.type}\u0000${sel.name || ''}\u0000${tab}`;
    if (cur && cur.key === key) {
      renderHeader(cur.header, sel);
      cur.view.update?.();
      return;
    }
    destroyView();
    content.replaceChildren();

    const header = h('div', { class: 'content-header' });
    const tabbar = h('div', { class: 'tabbar', role: 'tablist' },
      TABS[sel.type].map(([id, label]) => h('button', {
        type: 'button', role: 'tab', class: `tab${id === tab ? ' active' : ''}`,
        'aria-selected': id === tab ? 'true' : 'false',
        onclick: () => selectTab(id),
      }, label)));
    const body = h('div', { class: 'content-body', role: 'tabpanel' });
    content.append(header, tabbar, body);

    const factory = VIEWS[sel.type][tab] || VIEWS[sel.type].summary;
    const view = factory(sel.name);
    if (view.fullHeight) body.classList.add('full');
    body.append(view.el);
    cur = { key, view, header };
    renderHeader(header, sel);
    view.mounted?.();
  }

  function renderHeader(header, sel) {
    if (sel.type === 'host') {
      renderIfChanged(header, JSON.stringify(['host', state.host?.hostname]), () =>
        h('h2', {}, h('span', { class: 'kind' }, 'Host'), state.host?.hostname || ''));
    } else {
      const vm = vmByName(sel.name);
      renderIfChanged(header, JSON.stringify(['vm', sel.name, vm?.state, vm?.activity]), () => [
        h('h2', {}, h('span', { class: 'kind' }, 'VM'), sel.name),
        vm ? stateBadge(vm.state) : null,
        vm?.activity ? h('span', { class: 'badge info' }, h('span', { class: 'spinner' }), vm.activity) : null,
      ]);
    }
  }

  // ================================================================
  // Tasks panel
  // ================================================================

  function applyTasksOpen() {
    $('#tasks-panel').classList.toggle('collapsed', !state.tasksOpen);
    $('#tasks-toggle').setAttribute('aria-expanded', String(state.tasksOpen));
    lsSet('proxmacs.tasksOpen', state.tasksOpen);
  }

  function renderTasks() {
    const tasks = state.tasks.slice().sort((a, b) => String(b.started).localeCompare(String(a.started)));
    const running = tasks.filter((t) => t.status === 'running').length;
    const errors = tasks.filter((t) => t.status === 'error').length;
    $('#tasks-summary').textContent = tasks.length
      ? `${tasks.length} total · ${running} running${errors ? ` · ${errors} failed` : ''}`
      : '';

    const body = $('#tasks-body');
    renderIfChanged(body, JSON.stringify([tasks, [...state.expandedTasks]]), () => {
      if (!tasks.length) return h('div', { class: 'empty' }, 'No tasks yet.');
      const rows = [];
      for (const t of tasks) {
        const id = String(t.id);
        const expanded = state.expandedTasks.has(id);
        const toggle = () => {
          if (state.expandedTasks.has(id)) state.expandedTasks.delete(id); else state.expandedTasks.add(id);
          renderTasks();
        };
        rows.push(h('tr', {
          class: `task-row${expanded ? ' expanded' : ''}`, tabindex: '0', 'aria-expanded': String(expanded),
          onclick: toggle,
          onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); } },
        },
        h('td', { class: 'nowrap' }, fmtDate(t.started, timeFmt)),
        h('td', { class: 'nowrap' }, t.vm || '—'),
        h('td', {}, t.title || '',
          t.status === 'running' && typeof t.progress === 'number'
            ? h('div', { class: 'progress' }, h('div', { style: `width:${Math.round(Math.min(1, Math.max(0, t.progress)) * 100)}%` }))
            : null),
        h('td', { class: 'nowrap' }, taskStatus(t)),
        h('td', { class: 'task-msg', title: t.message || '' }, t.message || '')));
        if (expanded) {
          rows.push(h('tr', { class: 'task-detail' }, h('td', { colspan: '5' },
            h('div', { class: 'muted small' },
              `Task ${id} · started ${fmtDate(t.started, timeFmt)}`,
              t.finished ? ` · finished ${fmtDate(t.finished, timeFmt)} · took ${fmtDuration(t.started, t.finished)}` : ''),
            t.message ? h('pre', {}, t.message) : h('div', { class: 'muted' }, 'No message.'))));
        }
      }
      return h('table', { class: 'table' },
        h('thead', {}, h('tr', {}, ['Started', 'VM', 'Task', 'Status', 'Message'].map((c) => h('th', {}, c)))),
        h('tbody', {}, rows));
    });
  }

  function taskStatus(t) {
    if (t.status === 'running') {
      const pct = typeof t.progress === 'number' ? ` ${Math.round(t.progress * 100)}%` : '';
      return h('span', { class: 'task-status' }, h('span', { class: 'spinner' }), `running${pct}`);
    }
    if (t.status === 'ok') return h('span', { class: 'task-status ok' }, 'OK');
    if (t.status === 'error') return h('span', { class: 'task-status error' }, 'Error');
    return h('span', { class: 'task-status' }, t.status || '?');
  }

  // ================================================================
  // Shared UI pieces
  // ================================================================

  function panel(title, body, headerExtra, flush) {
    return h('section', { class: 'panel' },
      h('div', { class: 'panel-header' }, h('h3', {}, title), headerExtra ? [h('div', { class: 'spacer' }), headerExtra] : null),
      h('div', { class: `panel-body${flush ? ' flush' : ''}` }, body));
  }

  function kv(pairs) {
    return h('dl', { class: 'kv' }, pairs.filter(Boolean).map(([k, v]) => [h('dt', {}, k), h('dd', {}, v)]));
  }

  function actionBtn(label, opts, fn) {
    const b = h('button', { type: 'button', class: `btn ${opts.cls || ''}`, disabled: !!opts.disabled, title: opts.title || null }, label);
    b.addEventListener('click', () => busy(b, fn));
    // Disabled buttons don't reliably show tooltips; wrap so the hint still shows.
    return opts.disabled && opts.title ? h('span', { title: opts.title }, b) : b;
  }

  function interfaceLabel(device) {
    if (!device) return 'default interface';
    const i = state.interfaces.find((x) => x.device === device);
    return i ? `${i.name} (${device})` : device;
  }

  function networkLabel(net) {
    if (!net) return '—';
    if (net.mode === 'bridged') return `Bridged — ${interfaceLabel(net.interface)}`;
    if (net.mode === 'nat') return 'NAT (shared)';
    return String(net.mode || '—');
  }

  function backupLabel(b) {
    if (!b) return '—';
    return b.daily ? `Daily at ${pad2(b.hour)}:00, keep ${b.keep}` : `Scheduled backups off (keep ${b.keep})`;
  }

  function offsiteLabel(o) {
    if (!o || !o.targets || !o.targets.length) return 'None';
    const names = o.targets.map((id) => targetById(id)?.name || String(id)).join(', ');
    return `${names}${o.auto ? ' — pushed automatically after each backup' : ' — manual push only'}`;
  }

  function kindBadge(kind) {
    return h('span', { class: 'badge info' }, String(kind || '').toUpperCase());
  }

  /** Remote snapshot browser for one target and VM name; used by Offsite tab and host recovery. */
  function snapshotBrowser(targetId, getVmName) {
    const el = h('div', { class: 'snapshots' });
    let st = { status: 'idle', items: [] };
    let reqSeq = 0;

    function render() {
      el.replaceChildren();
      if (st.status === 'idle') return;
      if (st.status === 'loading' && !st.items.length) {
        el.append(h('div', { class: 'empty' }, h('span', { class: 'spinner' }), ' Loading snapshots…'));
        return;
      }
      if (st.status === 'error') {
        el.append(h('div', { class: 'empty error-text' }, st.message));
        return;
      }
      if (!st.items.length) {
        el.append(h('div', { class: 'empty' }, `No remote snapshots for “${st.vm}”.`));
        return;
      }
      el.append(h('table', { class: 'table' },
        h('thead', {}, h('tr', {}, h('th', {}, 'Time'), h('th', {}, 'Snapshot'), h('th', {}))),
        h('tbody', {}, st.items.map((s) => h('tr', {},
          h('td', { class: 'nowrap' }, fmtDate(s.time)),
          h('td', { class: 'wrap mono muted' }, s.id),
          h('td', { class: 'actions-cell' }, actionBtn('Pull', { cls: 'small', title: 'Copy this snapshot into local backups' }, () => pull(s))))))));
    }

    async function load() {
      const vm = getVmName();
      if (!vm) return;
      const seq = ++reqSeq;
      st = { status: 'loading', items: st.vm === vm ? st.items : [], vm };
      render();
      try {
        const items = await api('GET', `/api/targets/${enc(targetId)}/snapshots?vm=${enc(vm)}`);
        if (seq !== reqSeq) return;
        const list = (Array.isArray(items) ? items : []).slice().sort((a, b) => String(b.time).localeCompare(String(a.time)));
        st = { status: 'ok', items: list, vm };
      } catch (e) {
        if (e instanceof AuthError || seq !== reqSeq) return;
        st = { status: 'error', message: e.message, items: [], vm };
      }
      render();
    }

    async function pull(s) {
      const vm = s.vm || st.vm;
      const target = targetById(targetId);
      await startTask('POST', `/api/targets/${enc(targetId)}/pull`, { vm, id: s.id },
        `Pull ${vm} from ${target ? target.name : 'target'}`);
    }

    return { el, load, get loaded() { return st.status !== 'idle'; } };
  }

  // ================================================================
  // Host views
  // ================================================================

  function hostSummaryView() {
    const el = h('div', { class: 'view' });
    function update() {
      const host = state.host;
      renderIfChanged(el, JSON.stringify([host, state.vms.map((v) => v.state)]), () => {
        if (!host) return h('div', { class: 'empty' }, h('span', { class: 'spinner' }), ' Loading host information…');
        const used = host.diskTotalBytes ? 1 - host.diskFreeBytes / host.diskTotalBytes : 0;
        const meterCls = used > 0.9 ? 'err' : used > 0.75 ? 'warn' : '';
        const counts = {};
        for (const v of state.vms) counts[v.state] = (counts[v.state] || 0) + 1;
        return h('div', { class: 'grid2' },
          panel('Host', kv([
            ['Hostname', host.hostname || '—'],
            ['macOS', host.osVersion || '—'],
            ['Tart', host.tartVersion ? host.tartVersion : h('span', { class: 'badge err' }, 'not found')],
            ['CPUs', String(host.cpus ?? '—')],
            ['Memory', fmtBytes(host.memoryBytes)],
            ['Disk', h('div', {},
              `${fmtBytes(host.diskFreeBytes)} free of ${fmtBytes(host.diskTotalBytes)}`,
              host.diskTotalBytes ? h('div', { class: `meter ${meterCls}`, title: `${Math.round(used * 100)}% used` },
                h('div', { style: `width:${Math.round(used * 100)}%` })) : null)],
          ])),
          panel('Virtual machines', kv([
            ['Total', String(state.vms.length)],
            ['Running', h('span', { class: 'copy-line' }, stateDot('running'), String(counts.running || 0))],
            ['Stopped', h('span', { class: 'copy-line' }, stateDot('stopped'), String(counts.stopped || 0))],
            counts.suspended ? ['Suspended', h('span', { class: 'copy-line' }, stateDot('suspended'), String(counts.suspended))] : null,
            counts.missing ? ['Missing', h('span', { class: 'copy-line' }, stateDot('missing'), String(counts.missing))] : null,
          ])));
      });
    }
    update();
    return { el, update };
  }

  function imagesView() {
    const el = h('div', { class: 'view' });
    const box = h('div', {}, h('div', { class: 'empty' }, h('span', { class: 'spinner' }), ' Loading…'));
    const refreshBtn = h('button', { type: 'button', class: 'btn small' }, 'Refresh');
    refreshBtn.addEventListener('click', () => busy(refreshBtn, load));
    el.append(panel('Images', box, refreshBtn, true));
    el.append(h('p', { class: 'muted small' }, 'Images are downloaded on first use when creating a VM and cached on this Mac.'));

    async function load() {
      try {
        const images = await api('GET', '/api/images');
        box.replaceChildren(Array.isArray(images) && images.length
          ? h('table', { class: 'table' },
            h('thead', {}, h('tr', {}, h('th', {}, 'Name'), h('th', {}, 'ID'), h('th', {}, 'Cached'))),
            h('tbody', {}, images.map((img) => h('tr', {},
              h('td', {}, img.name || img.id),
              h('td', { class: 'mono muted wrap' }, img.id),
              h('td', {}, img.cached ? h('span', { class: 'badge ok' }, 'cached') : h('span', { class: 'badge' }, 'not downloaded'))))))
          : h('div', { class: 'empty' }, 'No images.'));
      } catch (e) {
        if (e instanceof AuthError) return;
        box.replaceChildren(h('div', { class: 'empty error-text' }, e.message));
      }
    }
    return { el, mounted: load };
  }

  function targetsView() {
    const el = h('div', { class: 'view' });
    const tableBox = h('div');
    const testResults = new Map(); // id -> {state: 'testing'|'ok'|'fail', message}

    function renderTable() {
      renderIfChanged(tableBox, JSON.stringify([state.targets, [...testResults]]), () => {
        if (!state.targets.length) return h('div', { class: 'empty' }, 'No backup targets yet. Add an SMB share or a Proxmox Backup Server below.');
        return h('table', { class: 'table' },
          h('thead', {}, h('tr', {}, ['Name', 'Kind', 'Location', 'Keep', 'Status', ''].map((c) => h('th', {}, c)))),
          h('tbody', {}, state.targets.map((t) => {
            const r = testResults.get(String(t.id));
            let status;
            if (!r) status = h('span', { class: 'muted' }, 'not tested');
            else if (r.state === 'testing') status = h('span', { class: 'task-status' }, h('span', { class: 'spinner' }), 'testing…');
            else if (r.state === 'ok') status = h('span', { class: 'badge ok', title: r.message || '' }, 'OK');
            else status = h('span', { class: 'badge err', title: r.message || '' }, 'Failed');
            return h('tr', {},
              h('td', {}, h('strong', {}, t.name)),
              h('td', {}, kindBadge(t.kind)),
              h('td', { class: 'wrap mono' }, t.location || ''),
              h('td', {}, String(t.keep ?? '—')),
              h('td', {}, status, r && r.message && r.state !== 'testing' ? h('div', { class: 'small muted wrap' }, r.message) : null),
              h('td', { class: 'actions-cell' }, h('div', { class: 'actions' },
                actionBtn('Test', { cls: 'small' }, () => testTarget(t)),
                actionBtn('Delete', { cls: 'small danger' }, () => deleteTarget(t)))));
          })));
      });
    }

    async function testTarget(t) {
      const id = String(t.id);
      testResults.set(id, { state: 'testing' });
      renderTable();
      try {
        const r = await api('POST', `/api/targets/${enc(t.id)}/test`, {});
        testResults.set(id, { state: r && r.ok ? 'ok' : 'fail', message: (r && r.message) || '' });
      } catch (e) {
        if (e instanceof AuthError) return;
        testResults.set(id, { state: 'fail', message: e.message });
      }
      renderTable();
    }

    async function deleteTarget(t) {
      const ok = await confirmDialog({
        title: 'Delete backup target',
        message: `Delete backup target “${t.name}”? Snapshots already stored on it are not removed, but VMs will stop pushing to it.`,
        confirmLabel: 'Delete', danger: true,
      });
      if (!ok) return;
      await api('DELETE', `/api/targets/${enc(t.id)}`, {});
      testResults.delete(String(t.id));
      toast(`Target “${t.name}” deleted`, 'ok');
      await loadTargets();
      renderTable();
    }

    // ---- Add target form
    const kindSmb = h('input', { type: 'radio', name: 'kind', value: 'smb', checked: true });
    const kindPbs = h('input', { type: 'radio', name: 'kind', value: 'pbs' });
    const f = {
      name: h('input', { type: 'text', required: true, maxlength: '64', placeholder: 'e.g. nas', autocomplete: 'off' }),
      keep: h('input', { type: 'number', required: true, min: '1', max: '999', step: '1', value: '7' }),
      smbUrl: h('input', { type: 'text', required: true, placeholder: 'smb://user@host/share/path', pattern: 'smb://[^@/\\s]+@[^/\\s]+/\\S+', title: 'smb://user@host/share[/path]', autocomplete: 'off', spellcheck: 'false' }),
      smbPassword: h('input', { type: 'password', autocomplete: 'new-password' }),
      pbsHost: h('input', { type: 'text', required: true, placeholder: 'pbs.lan or 192.168.1.20', autocomplete: 'off', spellcheck: 'false' }),
      pbsPort: h('input', { type: 'number', required: true, min: '1', max: '65535', step: '1', value: '8007' }),
      pbsDatastore: h('input', { type: 'text', required: true, placeholder: 'datastore', autocomplete: 'off', spellcheck: 'false' }),
      pbsNamespace: h('input', { type: 'text', placeholder: 'optional', autocomplete: 'off', spellcheck: 'false' }),
      pbsAuthId: h('input', { type: 'text', required: true, placeholder: 'user@pbs!proxmacs', pattern: '[^@\\s]+@[^!\\s]+![^\\s]+', title: 'user@realm!tokenname', autocomplete: 'off', spellcheck: 'false' }),
      pbsSecret: h('input', { type: 'password', required: true, placeholder: 'token secret', autocomplete: 'new-password' }),
      pbsFingerprint: h('input', { type: 'text', placeholder: 'aa:bb:cc:… (optional)', pattern: '([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}', title: 'SHA-256 fingerprint: 32 hex byte pairs separated by colons', autocomplete: 'off', spellcheck: 'false' }),
    };
    const field = (label, input, hint, cls) => h('label', { class: `field ${cls || ''}` }, h('span', {}, label), input, hint ? h('span', { class: 'hint' }, hint) : null);

    const smbSet = h('fieldset', { class: 'form-grid span2' },
      field('URL', f.smbUrl, 'smb://user@host/share[/path]', 'span2'),
      field('Password', f.smbPassword, 'Stored on this Mac in an owner-only file; never shown again.', 'span2'));
    const pbsSet = h('fieldset', { class: 'form-grid span2' },
      field('Host', f.pbsHost),
      field('Port', f.pbsPort),
      field('Datastore', f.pbsDatastore),
      field('Namespace', f.pbsNamespace),
      field('Auth ID', f.pbsAuthId, 'API token: user@realm!tokenname'),
      field('Token secret', f.pbsSecret, 'Stored on this Mac in an owner-only file; never shown again.'),
      field('TLS fingerprint', f.pbsFingerprint, 'SHA-256, needed for self-signed certificates.', 'span2'));

    function syncKind() {
      const pbs = kindPbs.checked;
      smbSet.hidden = pbs; smbSet.disabled = pbs;
      pbsSet.hidden = !pbs; pbsSet.disabled = !pbs;
    }
    kindSmb.addEventListener('change', syncKind);
    kindPbs.addEventListener('change', syncKind);
    syncKind();

    const addBtn = h('button', { type: 'submit', class: 'btn primary' }, 'Add target');
    const form = h('form', { autocomplete: 'off' },
      h('div', { class: 'form-grid' },
        h('div', { class: 'field span2' }, h('span', {}, 'Kind'),
          h('div', { class: 'segmented', role: 'radiogroup' },
            h('label', {}, kindSmb, 'SMB share'),
            h('label', {}, kindPbs, 'Proxmox Backup Server'))),
        field('Name', f.name),
        field('Keep', f.keep, 'Snapshots kept per VM on this target'),
        smbSet, pbsSet),
      h('div', { class: 'form-actions' }, addBtn));

    form.addEventListener('submit', (e) => {
      e.preventDefault();
      busy(addBtn, async () => {
        const kind = kindPbs.checked ? 'pbs' : 'smb';
        const body = { name: f.name.value.trim(), kind, keep: parseInt(f.keep.value, 10) };
        if (kind === 'smb') {
          body.smb = { url: f.smbUrl.value.trim(), password: f.smbPassword.value };
        } else {
          body.pbs = {
            host: f.pbsHost.value.trim(),
            port: parseInt(f.pbsPort.value, 10),
            datastore: f.pbsDatastore.value.trim(),
            namespace: f.pbsNamespace.value.trim() || null,
            authId: f.pbsAuthId.value.trim(),
            secret: f.pbsSecret.value,
            fingerprint: f.pbsFingerprint.value.trim().toLowerCase() || null,
          };
        }
        const t = await api('POST', '/api/targets', body);
        toast(`Target “${(t && t.name) || body.name}” added`, 'ok');
        form.reset();
        kindSmb.checked = true;
        syncKind();
        await loadTargets();
        renderTable();
      });
    });

    // ---- Recover from offsite (VMs that no longer exist locally)
    const recTarget = h('select', {});
    const recVm = h('input', { type: 'text', placeholder: 'VM name', autocomplete: 'off', spellcheck: 'false' });
    const recResults = h('div');
    let recBrowser = null;
    const recBtn = h('button', { type: 'submit', class: 'btn' }, 'List snapshots');
    const recForm = h('form', {},
      h('p', { class: 'muted' }, 'Browse a target’s snapshots by VM name — also for VMs that no longer exist here. Pulling copies the snapshot into local backups; if the VM does not exist anymore it is recreated from the snapshot.'),
      h('div', { class: 'form-row' },
        field('Target', recTarget),
        field('VM name', recVm),
        recBtn),
      recResults);
    recForm.addEventListener('submit', (e) => {
      e.preventDefault();
      const tid = recTarget.value, vm = recVm.value.trim();
      if (!tid || !vm) return;
      recBrowser = snapshotBrowser(tid, () => vm);
      recResults.replaceChildren(h('div', { style: 'margin-top:12px' }, recBrowser.el));
      busy(recBtn, () => recBrowser.load());
    });
    const recPanel = panel('Recover from offsite', recForm);

    function renderRecoverTargets() {
      renderIfChanged(recTarget, JSON.stringify(state.targets.map((t) => [t.id, t.name])), () => {
        const prev = recTarget.value;
        const opts = state.targets.map((t) => h('option', { value: String(t.id) }, `${t.name} (${String(t.kind).toUpperCase()})`));
        queueMicrotask(() => { if (state.targets.some((t) => String(t.id) === prev)) recTarget.value = prev; });
        return opts;
      });
      recPanel.hidden = !state.targets.length;
    }

    el.append(
      panel('Backup targets', tableBox, null, true),
      panel('Add target', form),
      recPanel);
    renderTable();
    renderRecoverTargets();

    return {
      el,
      mounted: () => loadTargets().then(() => { renderTable(); renderRecoverTargets(); }),
      update: () => { renderTable(); renderRecoverTargets(); },
    };
  }

  // ================================================================
  // VM views
  // ================================================================

  async function vmStart(vm) { await startTask('POST', `/api/vms/${enc(vm.name)}/start`, {}, `Start ${vm.name}`); }
  async function vmStop(vm) { await startTask('POST', `/api/vms/${enc(vm.name)}/stop`, {}, `Shutdown ${vm.name}`); }
  async function vmBackup(vm) { await startTask('POST', `/api/vms/${enc(vm.name)}/backup`, {}, `Back up ${vm.name}`); }
  async function vmDelete(vm) {
    const ok = await confirmDialog({
      title: `Delete VM ${vm.name}`,
      message: `This permanently deletes the VM “${vm.name}” and its disk. Local backups and offsite snapshots are kept.`,
      confirmLabel: 'Delete VM', danger: true, requireText: vm.name,
    });
    if (!ok) return;
    await startTask('DELETE', `/api/vms/${enc(vm.name)}`, {}, `Delete ${vm.name}`);
  }

  function vmSummaryView(name) {
    const el = h('div', { class: 'view' });
    function update() {
      const vm = vmByName(name);
      if (!vm) return;
      const sig = JSON.stringify([vm, state.interfaces, state.targets.map((t) => [t.id, t.name])]);
      renderIfChanged(el, sig, () => build(vm));
    }
    function build(vm) {
      const running = vm.state === 'running';
      const canStart = vm.state === 'stopped' || vm.state === 'suspended';
      const ssh = vm.ip ? `ssh debian@${vm.ip}` : null;

      const autostart = h('input', { type: 'checkbox', class: 'switch', checked: !!vm.autostart, 'aria-label': 'Start on login' });
      autostart.addEventListener('change', async () => {
        autostart.disabled = true;
        try {
          updateVm(await api('PATCH', `/api/vms/${enc(name)}`, { autostart: autostart.checked }));
        } catch (e) {
          reportError(e);
          el._sig = undefined; update();
        }
      });

      let ipCell;
      if (ssh) {
        const copyBtn = h('button', { type: 'button', class: 'btn small' }, 'Copy');
        copyBtn.addEventListener('click', async () => {
          const ok = await copyText(ssh);
          copyBtn.textContent = ok ? 'Copied' : 'Copy failed';
          setTimeout(() => { if (copyBtn.isConnected) copyBtn.textContent = 'Copy'; }, 1500);
        });
        ipCell = h('div', {}, h('div', { class: 'mono' }, vm.ip),
          h('div', { class: 'copy-line', style: 'margin-top:4px' }, h('code', {}, ssh), copyBtn));
      } else {
        ipCell = h('span', { class: 'muted' }, running ? 'waiting for an address…' : '—');
      }

      return [
        h('div', { class: 'toolbar' },
          actionBtn('Start', { cls: 'primary', disabled: !canStart, title: canStart ? null : (running ? 'Already running' : `Cannot start a ${vm.state} VM`) }, () => vmStart(vm)),
          actionBtn('Shutdown', { disabled: !running, title: running ? null : 'The VM is not running' }, () => vmStop(vm)),
          actionBtn('Back up now', { disabled: vm.state === 'missing', title: vm.state === 'missing' ? 'The VM is missing' : null }, () => vmBackup(vm)),
          h('div', { class: 'spacer' }),
          actionBtn('Delete', { cls: 'danger' }, () => vmDelete(vm))),
        h('div', { class: 'grid2' },
          panel('Status', kv([
            ['State', h('span', { class: 'copy-line' }, stateBadge(vm.state),
              vm.activity ? h('span', { class: 'badge info' }, h('span', { class: 'spinner' }), vm.activity) : null)],
            ['IP address', ipCell],
            ['Network', networkLabel(vm.network)],
            ['Start on login', h('label', { class: 'check' }, autostart, vm.autostart ? 'On' : 'Off')],
          ])),
          panel('Hardware', kv([
            ['CPUs', vm.cpus != null ? String(vm.cpus) : '—'],
            ['Memory', fmtMemMB(vm.memoryMB)],
            ['Disk', vm.diskGB != null ? `${vm.diskGB} GB` : '—'],
          ])),
          panel('Protection', kv([
            ['Local backups', backupLabel(vm.backup)],
            ['Offsite', offsiteLabel(vm.offsite)],
          ]))),
        vm.state === 'missing'
          ? h('div', { class: 'note' }, 'This VM is registered with Proxmacs but its Tart VM was not found. Restore it from the Backups tab, or pull a snapshot from the Offsite tab.')
          : null,
      ];
    }
    update();
    return { el, update };
  }

  function consoleView(name) {
    const el = h('div', { class: 'view' });
    const statusEl = h('span', { class: 'badge' }, 'Not connected');
    const reconnectBtn = h('button', { type: 'button', class: 'btn small' }, 'Reconnect');
    const termHost = h('div', { class: 'term-host' });
    const overlayMsg = h('div', { class: 'small' });
    const overlayBtn = h('button', { type: 'button', class: 'btn primary' }, 'Reconnect');
    const overlay = h('div', { class: 'term-overlay', hidden: true }, h('strong', {}, 'Disconnected'), overlayMsg, overlayBtn);
    const termBox = h('div', { class: 'term-box' }, termHost, overlay);
    el.append(
      h('div', { class: 'console-toolbar' },
        h('span', { class: 'muted' }, 'Serial console (hvc0). Press Enter for a login prompt.'),
        h('div', { class: 'spacer' }), statusEl, reconnectBtn),
      termBox);

    let term = null, fit = null, ws = null, ro = null, disposed = false, lastClose = null;

    function setStatus(text, cls) {
      statusEl.className = `badge ${cls || ''}`;
      statusEl.textContent = text;
    }

    function safeFit() {
      if (!fit || !termHost.offsetWidth || !termHost.offsetHeight) return;
      try { fit.fit(); } catch { /* ignore */ }
    }

    function overlayText() {
      const vm = vmByName(name);
      if (vm && vm.state !== 'running') return `The VM is ${vm.state}. Start it, then reconnect.`;
      if (lastClose && lastClose.reason) return lastClose.reason;
      return 'The console connection was closed.';
    }

    function closeWs() {
      if (!ws) return;
      const s = ws;
      ws = null;
      s.onopen = s.onmessage = s.onclose = s.onerror = null;
      try { s.close(); } catch { /* ignore */ }
    }

    function connect() {
      if (disposed || !term) return;
      closeWs();
      overlay.hidden = true;
      setStatus('Connecting…', 'warn');
      const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
      let sock;
      try {
        sock = new WebSocket(`${proto}//${location.host}/api/vms/${enc(name)}/console`);
      } catch (e) {
        lastClose = { reason: e.message };
        showDisconnected();
        return;
      }
      sock.binaryType = 'arraybuffer';
      ws = sock;
      sock.onopen = () => {
        if (ws !== sock) return;
        setStatus('Connected', 'ok');
        term.focus();
      };
      sock.onmessage = (ev) => {
        if (ws !== sock || !term) return;
        const d = ev.data;
        if (typeof d === 'string') term.write(d);
        else if (d instanceof ArrayBuffer) term.write(new Uint8Array(d));
        else if (d && typeof d.arrayBuffer === 'function') d.arrayBuffer().then((b) => { if (term) term.write(new Uint8Array(b)); });
      };
      sock.onclose = (ev) => {
        if (ws !== sock) return;
        ws = null;
        lastClose = { code: ev.code, reason: ev.reason };
        showDisconnected();
      };
      sock.onerror = () => { /* a close event follows */ };
    }

    function showDisconnected() {
      setStatus('Disconnected', 'err');
      overlayMsg.textContent = overlayText();
      overlay.hidden = false;
    }

    overlayBtn.addEventListener('click', connect);
    reconnectBtn.addEventListener('click', connect);

    function mounted() {
      if (typeof Terminal === 'undefined' || typeof FitAddon === 'undefined') {
        termBox.replaceChildren(h('div', { class: 'term-overlay' }, h('strong', {}, 'Terminal component failed to load.')));
        return;
      }
      term = new Terminal({
        cursorBlink: true,
        convertEol: false,
        scrollback: 5000,
        fontSize: 13,
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace',
        theme: { background: '#0c0c0c', foreground: '#e6e6e6', cursor: '#e6e6e6' },
      });
      fit = new FitAddon.FitAddon();
      term.loadAddon(fit);
      term.open(termHost);
      term.onData((data) => {
        if (ws && ws.readyState === WebSocket.OPEN) ws.send(data);
      });
      safeFit();
      if (typeof ResizeObserver !== 'undefined') {
        ro = new ResizeObserver(() => safeFit());
        ro.observe(termBox);
      }
      connect();
      term.focus();
    }

    function update() {
      if (!overlay.hidden) overlayMsg.textContent = overlayText();
    }

    function destroy() {
      disposed = true;
      closeWs();
      ro?.disconnect();
      try { term?.dispose(); } catch { /* ignore */ }
      term = null; fit = null;
    }

    return { el, mounted, update, destroy, fullHeight: true };
  }

  function backupsView(name) {
    const el = h('div', { class: 'view' });

    // ---- schedule editor
    const daily = h('input', { type: 'checkbox', class: 'switch' });
    const hour = h('select', {}, Array.from({ length: 24 }, (_, i) => h('option', { value: String(i) }, `${pad2(i)}:00`)));
    const keep = h('input', { type: 'number', min: '1', max: '999', step: '1', required: true, style: 'width:90px' });
    const saveBtn = h('button', { type: 'submit', class: 'btn primary' }, 'Save');
    let dirty = false;
    let shownSig = null;

    function setFields(b) {
      b = b || { daily: false, hour: 3, keep: 7 };
      daily.checked = !!b.daily;
      hour.value = String(b.hour ?? 3);
      keep.value = String(b.keep ?? 7);
      hour.disabled = !daily.checked;
      shownSig = JSON.stringify(b);
      dirty = false;
    }
    for (const i of [daily, hour, keep]) i.addEventListener('input', () => { dirty = true; hour.disabled = !daily.checked; });
    daily.addEventListener('change', () => { dirty = true; hour.disabled = !daily.checked; });

    const schedForm = h('form', {},
      h('div', { class: 'form-row' },
        h('label', { class: 'check', style: 'height:28px' }, daily, 'Daily backup'),
        h('label', { class: 'field' }, h('span', {}, 'At'), hour),
        h('label', { class: 'field' }, h('span', {}, 'Keep'), keep),
        saveBtn),
      h('p', { class: 'muted small', style: 'margin:10px 0 0' }, 'Keep = number of local backups retained; older ones are pruned automatically.'));
    schedForm.addEventListener('submit', (e) => {
      e.preventDefault();
      busy(saveBtn, async () => {
        const backup = { daily: daily.checked, hour: parseInt(hour.value, 10), keep: parseInt(keep.value, 10) };
        const vm = await api('PATCH', `/api/vms/${enc(name)}`, { backup });
        setFields(vm && vm.backup ? vm.backup : backup);
        updateVm(vm);
        toast('Backup schedule saved', 'ok');
      });
    });

    // ---- backups list
    const listBox = h('div', {}, h('div', { class: 'empty' }, h('span', { class: 'spinner' }), ' Loading backups…'));
    let backups = null, loadError = null, seq = 0;

    const backupNowBtn = h('button', { type: 'button', class: 'btn primary small' }, 'Back up now');
    backupNowBtn.addEventListener('click', () => busy(backupNowBtn, () => { const vm = vmByName(name); return vm && vmBackup(vm); }));
    const refreshBtn = h('button', { type: 'button', class: 'btn small' }, 'Refresh');
    refreshBtn.addEventListener('click', () => busy(refreshBtn, load));

    async function load() {
      const my = ++seq;
      try {
        const list = await api('GET', `/api/vms/${enc(name)}/backups`);
        if (my !== seq) return;
        backups = Array.isArray(list) ? list : [];
        loadError = null;
      } catch (e) {
        if (e instanceof AuthError || my !== seq) return;
        loadError = e.message;
      }
      renderList();
    }

    function renderList() {
      const vm = vmByName(name);
      if (!vm) return;
      const sig = JSON.stringify([backups, loadError, vm.state, state.targets.map((t) => [t.id, t.name])]);
      renderIfChanged(listBox, sig, () => {
        if (loadError) return h('div', { class: 'empty error-text' }, loadError);
        if (!backups) return h('div', { class: 'empty' }, h('span', { class: 'spinner' }), ' Loading backups…');
        if (!backups.length) return h('div', { class: 'empty' }, 'No local backups yet.');
        const running = vm.state === 'running';
        return h('table', { class: 'table' },
          h('thead', {}, h('tr', {}, ['Date', 'Type', 'Source', ''].map((c) => h('th', {}, c)))),
          h('tbody', {}, backups.map((b) => h('tr', {},
            h('td', { class: 'nowrap', title: b.id }, fmtDate(b.date)),
            h('td', {}, b.consistent
              ? h('span', { class: 'badge ok', title: 'Taken while the VM was stopped or quiesced' }, 'consistent')
              : h('span', { class: 'badge warn', title: 'Taken while the VM was running' }, 'crash-consistent')),
            h('td', { class: 'muted wrap' }, b.source || '—'),
            h('td', { class: 'actions-cell' }, h('div', { class: 'actions' },
              actionBtn('Restore', { cls: 'small', disabled: running, title: running ? 'Stop the VM first' : null }, () => restore(b)),
              pushSelect(b),
              actionBtn('Delete', { cls: 'small danger' }, () => del(b))))))));
      });
    }

    function pushSelect(b) {
      const sel = h('select', { class: 'small', disabled: !state.targets.length, title: state.targets.length ? 'Copy this backup to an offsite target' : 'No backup targets configured', value: '' },
        h('option', { value: '' }, state.targets.length ? 'Push to…' : 'Push to… (no targets)'),
        state.targets.map((t) => h('option', { value: String(t.id) }, t.name)));
      sel.addEventListener('change', async () => {
        const tid = sel.value;
        if (!tid) return;
        const t = targetById(tid);
        sel.disabled = true;
        try {
          await startTask('POST', `/api/vms/${enc(name)}/backups/${enc(b.id)}/push`, { target: t ? t.id : tid },
            `Push ${name} backup to ${t ? t.name : 'target'}`);
        } catch (e) { reportError(e); } finally {
          sel.value = '';
          sel.disabled = false;
        }
      });
      return sel;
    }

    async function restore(b) {
      const ok = await confirmDialog({
        title: `Restore ${name}`,
        message: `Restore “${name}” from the backup of ${fmtDate(b.date)}? The VM’s current disk will be replaced; changes since then are lost.`,
        confirmLabel: 'Restore', danger: true,
      });
      if (!ok) return;
      await startTask('POST', `/api/vms/${enc(name)}/backups/${enc(b.id)}/restore`, {}, `Restore ${name}`);
    }

    async function del(b) {
      const ok = await confirmDialog({
        title: 'Delete backup',
        message: `Delete the local backup of “${name}” from ${fmtDate(b.date)}? This cannot be undone.`,
        confirmLabel: 'Delete', danger: true,
      });
      if (!ok) return;
      await api('DELETE', `/api/vms/${enc(name)}/backups/${enc(b.id)}`, {});
      toast('Backup deleted', 'ok');
      await load();
    }

    el.append(
      panel('Schedule', schedForm),
      panel('Local backups', listBox, h('div', { class: 'actions' }, refreshBtn, backupNowBtn), true));

    setFields(vmByName(name)?.backup);

    function update() {
      const vm = vmByName(name);
      if (vm && !dirty && JSON.stringify(vm.backup) !== shownSig) setFields(vm.backup);
      backupNowBtn.disabled = !vm || vm.state === 'missing';
      renderList();
    }

    return {
      el,
      mounted: () => { update(); load(); },
      update,
      onTaskFinished: (t) => { if (t.vm === name) load(); },
    };
  }

  function offsiteView(name) {
    const el = h('div', { class: 'view' });
    const settingsBox = h('div');
    const remoteBox = h('div');
    const browsers = new Map(); // target id -> snapshotBrowser
    let saving = false;

    function renderSettings() {
      const vm = vmByName(name);
      if (!vm) return;
      const sig = JSON.stringify([vm.offsite, state.targets.map((t) => [t.id, t.name, t.kind, t.location]), saving]);
      renderIfChanged(settingsBox, sig, () => {
        if (!state.targets.length) {
          return h('div', { class: 'empty' },
            h('p', {}, 'No backup targets configured.'),
            h('button', { type: 'button', class: 'btn', onclick: () => select('host', null, 'targets') }, 'Manage backup targets'));
        }
        const offsite = vm.offsite || { targets: [], auto: false };
        const chosen = new Set((offsite.targets || []).map(String));
        const auto = h('input', { type: 'checkbox', class: 'switch', checked: !!offsite.auto, disabled: saving });
        const checks = state.targets.map((t) => {
          const cb = h('input', { type: 'checkbox', value: String(t.id), checked: chosen.has(String(t.id)), disabled: saving });
          return { t, cb };
        });
        const save = async () => {
          saving = true;
          const body = { offsite: { targets: checks.filter((c) => c.cb.checked).map((c) => c.t.id), auto: auto.checked } };
          for (const c of [auto, ...checks.map((x) => x.cb)]) c.disabled = true;
          try {
            updateVm(await api('PATCH', `/api/vms/${enc(name)}`, body));
          } catch (e) {
            reportError(e);
          } finally {
            saving = false;
            settingsBox._sig = undefined;
            renderSettings();
          }
        };
        auto.addEventListener('change', save);
        for (const c of checks) c.cb.addEventListener('change', save);
        return [
          h('label', { class: 'check' }, auto, h('span', {}, h('strong', {}, 'Push automatically'), ' after each local backup to the selected targets')),
          h('div', { class: 'target-checks' }, checks.map(({ t, cb }) => h('label', { class: 'check' }, cb,
            h('span', {}, h('strong', {}, t.name), ' ', kindBadge(t.kind), h('div', { class: 'muted small mono wrap' }, t.location || ''))))),
        ];
      });
    }

    function renderRemote() {
      const ids = state.targets.map((t) => String(t.id));
      for (const id of [...browsers.keys()]) if (!ids.includes(id)) browsers.delete(id);
      renderIfChanged(remoteBox, JSON.stringify(state.targets.map((t) => [t.id, t.name, t.kind, t.location])), () =>
        state.targets.map((t) => {
          const id = String(t.id);
          if (!browsers.has(id)) browsers.set(id, snapshotBrowser(t.id, () => name));
          const br = browsers.get(id);
          const loadBtn = h('button', { type: 'button', class: 'btn small' }, br.loaded ? 'Refresh' : 'Load snapshots');
          loadBtn.addEventListener('click', () => busy(loadBtn, async () => { await br.load(); loadBtn.textContent = 'Refresh'; }));
          return panel(`Remote snapshots — ${t.name}`, br.el,
            h('div', { class: 'actions' }, kindBadge(t.kind), loadBtn), true);
        }));
    }

    el.append(
      panel('Offsite settings', settingsBox),
      h('p', { class: 'muted small' }, 'Pulling a snapshot copies it into this VM’s local backups; restore it from the Backups tab. If the VM no longer exists, it is recreated from the snapshot.'),
      remoteBox);

    function update() { renderSettings(); renderRemote(); }
    update();

    return {
      el,
      update,
      onTaskFinished: (t) => {
        if (t.vm !== name) return;
        for (const br of browsers.values()) if (br.loaded) br.load();
      },
    };
  }

  const VIEWS = {
    host: { summary: hostSummaryView, targets: targetsView, images: imagesView },
    vm: { summary: vmSummaryView, console: consoleView, backups: backupsView, offsite: offsiteView },
  };

  // ================================================================
  // Create VM dialog
  // ================================================================

  let creating = false;

  async function openCreateVm() {
    if (creating) return;
    creating = true;
    const btn = $('#create-vm');
    btn.disabled = true;
    let interfaces = [], images = [];
    try {
      [interfaces, images] = await Promise.all([api('GET', '/api/interfaces'), api('GET', '/api/images')]);
      interfaces = Array.isArray(interfaces) ? interfaces : [];
      images = Array.isArray(images) ? images : [];
      state.interfaces = interfaces;
    } catch (e) {
      reportError(e);
      return;
    } finally {
      creating = false;
      btn.disabled = false;
    }

    const hostCpus = Math.max(1, state.host?.cpus || 4);
    const hostMemGB = state.host?.memoryBytes ? state.host.memoryBytes / 2 ** 30 : Infinity;
    const field = (label, input, hint) => h('label', { class: 'field' }, h('span', {}, label), input, hint ? h('span', { class: 'hint' }, hint) : null);

    const name = h('input', {
      type: 'text', required: true, autofocus: true, maxlength: '63', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
      pattern: '[A-Za-z0-9][A-Za-z0-9._\\-]*', title: 'Letters, digits, dot, dash and underscore; must start with a letter or digit', placeholder: 'e.g. web01',
    });
    name.addEventListener('input', () => name.setCustomValidity(vmByName(name.value.trim()) ? 'A VM with this name already exists' : ''));

    const cpus = h('select', { value: String(Math.min(2, hostCpus)) },
      Array.from({ length: hostCpus }, (_, i) => h('option', { value: String(i + 1) }, String(i + 1))));
    const memOptions = [1, 2, 4, 8, 16];
    const memDefault = hostMemGB >= 16 ? 4 : 2;
    const memory = h('select', { value: String(memDefault * 1024) },
      memOptions.map((gb) => h('option', { value: String(gb * 1024), disabled: gb >= hostMemGB }, `${gb} GB`)));
    const disk = h('input', { type: 'number', required: true, min: '10', max: '4096', step: '1', value: '20' });

    const defaultIface = interfaces.find((i) => i.default) || interfaces[0];
    const mode = h('select', { value: interfaces.length ? 'bridged' : 'nat' },
      h('option', { value: 'bridged', disabled: !interfaces.length }, 'Bridged'),
      h('option', { value: 'nat' }, 'NAT'));
    const iface = h('select', { value: defaultIface ? defaultIface.device : '' },
      interfaces.map((i) => h('option', { value: i.device }, `${i.name} (${i.device})${i.default ? ' — default' : ''}`)));
    const ifaceField = field('Interface', iface);
    const syncMode = () => { ifaceField.hidden = mode.value !== 'bridged'; iface.disabled = mode.value !== 'bridged'; };
    mode.addEventListener('change', syncMode);
    syncMode();

    const defaultImage = images.find((i) => i.id === 'debian13') || images[0];
    const image = h('select', { required: true, value: defaultImage ? defaultImage.id : '' },
      images.map((i) => h('option', { value: i.id }, `${i.name || i.id}${i.cached ? '' : ' (will be downloaded)'}`)));

    const password = h('input', { type: 'password', autocomplete: 'new-password' });
    const autostart = h('input', { type: 'checkbox' });
    const startNow = h('input', { type: 'checkbox', checked: true });

    const submit = h('button', { type: 'submit', class: 'btn primary' }, 'Create');
    const form = h('form', { autocomplete: 'off' },
      h('div', { class: 'modal-body' },
        h('div', { class: 'form-grid' },
          h('div', { class: 'span2' }, field('Name', name)),
          field('CPUs', cpus, `Host has ${hostCpus}`),
          field('Memory', memory),
          field('Disk (GB)', disk),
          field('Image', image),
          field('Network', mode, 'Bridged: VM gets its own LAN address. NAT: private address behind this Mac.'),
          ifaceField,
          h('div', { class: 'span2' }, field('Console password', password, 'Optional.')),
          h('div', { class: 'span2', style: 'display:flex;gap:24px;flex-wrap:wrap' },
            h('label', { class: 'check' }, autostart, 'Start on login'),
            h('label', { class: 'check' }, startNow, 'Start now')))),
      h('div', { class: 'modal-footer' },
        h('button', { type: 'button', class: 'btn', onclick: () => m.close() }, 'Cancel'),
        submit));

    form.addEventListener('submit', (e) => {
      e.preventDefault();
      busy(submit, async () => {
        const vmName = name.value.trim();
        const body = {
          name: vmName,
          cpus: parseInt(cpus.value, 10),
          memoryMB: parseInt(memory.value, 10),
          diskGB: parseInt(disk.value, 10),
          network: { mode: mode.value, interface: mode.value === 'bridged' ? (iface.value || null) : null },
          image: image.value,
          password: password.value ? password.value : null,
          autostart: autostart.checked,
          startNow: startNow.checked,
        };
        await startTask('POST', '/api/vms', body, `Create ${vmName}`);
        m.close();
        state.tasksOpen = true;
        applyTasksOpen();
      });
    });

    const m = openModal({ title: 'Create VM', content: form });
  }

  // ================================================================
  // Go
  // ================================================================

  boot();
})();
