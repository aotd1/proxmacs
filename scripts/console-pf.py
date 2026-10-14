#!/usr/bin/python3
"""Root-owned PF policy and health monitor for the dedicated Tart service account.

Only the installer mutates policy. The monitor never silently repairs a changed
firewall; it withdraws readiness, causing active console supervisors to stop.
"""
import json
import os
import pathlib
import re
import signal
import stat
import subprocess
import tempfile
import time

ANCHOR = 'com.apple/000.proxmacs-console'
LABEL = 'proxmacs-console-owner'
BASE = pathlib.Path('/Library/Application Support/ProxmacsConsolePF')
CONFIG = BASE / 'config.json'
READY = BASE / 'ready.json'
TOKEN = BASE / 'token.json'


def command(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, timeout=10, check=True, **kwargs)


def pf(*args, **kwargs):
    return command(['/sbin/pfctl', *args], **kwargs)


def rules(uid):
    if type(uid) is not int or uid < 500:
        raise ValueError('Use a dedicated non-root VM account')
    return f'block drop in quick on ! lo0 proto tcp from any to any user = {uid} flags S/SA label "{LABEL}"\n'


def lines(text):
    return [line.strip() for line in text.splitlines() if line.strip()]


def root_rules_safe(text):
    # Reject unknown root policy rather than risk an earlier quick-pass bypass.
    filtered = [line for line in lines(text) if not line.startswith('scrub-anchor ')]
    return filtered in (['anchor "com.apple/*" all'],
                        ['anchor "com.apple/*" all', 'anchor "com.apple.internet-sharing" all'])


def anchor_rules_safe(text, uid, username):
    expected = rules(uid).strip().replace('from any to any', 'all')
    actual = text.strip().replace('user = ' + username + ' ', 'user = ' + str(uid) + ' ')
    return actual.replace('from any to any', 'all') == expected


def interfaces_safe(text):
    current = None
    seen = False
    for line in text.splitlines():
        if line and not line[0].isspace():
            current = line.split()[0]
            seen = True
        if re.search(r'\bskip\b', line, re.I) and current != 'lo0':
            return False
    return seen


def atomic_json(path, data, mode=0o600):
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.pf-')
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream)
        os.replace(name, path)
    finally:
        pathlib.Path(name).unlink(missing_ok=True)


def trusted(path):
    path = pathlib.Path(path)
    for item in [path, *path.parents]:
        info = item.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise RuntimeError('PF control path is not exclusively root-owned')
    return path


def configuration():
    trusted(CONFIG)
    data = json.loads(CONFIG.read_text())
    rules(data['uid'])
    if not re.fullmatch(r'[a-z_][a-z0-9_-]*', data['owner']):
        raise RuntimeError('Invalid owner')
    return data


def check(config):
    if not re.search(r'^Status:\s+Enabled\b', pf('-s', 'info').stdout, re.M):
        raise RuntimeError('PF disabled')
    if not root_rules_safe(pf('-sr').stdout):
        raise RuntimeError('Unexpected root PF rules; console protection not proven')
    children = lines(pf('-a', 'com.apple', '-s', 'Anchors').stdout)
    own = ANCHOR.split('/')[1]
    children = [name.rsplit('/', 1)[-1] for name in children]
    if own not in children or any(name < own for name in children):
        raise RuntimeError('Console anchor is not first')
    if not anchor_rules_safe(pf('-a', ANCHOR, '-sr').stdout, config['uid'], config['owner']):
        raise RuntimeError('Console PF rules changed')
    if not interfaces_safe(pf('-v', '-s', 'Interfaces').stdout):
        raise RuntimeError('PF interface skipping prevents protection')


def boot_id():
    return command(['/usr/sbin/sysctl', '-n', 'kern.boottime']).stdout.strip()


def initialize(config):
    """Boot/installation only. Existing nonstandard root policy is never replaced."""
    root = pf('-sr').stdout
    if not root.strip():
        if not re.search(r'^Status:\s+Disabled\b', pf('-s', 'info').stdout, re.M):
            raise RuntimeError('Refusing to initialize an already enabled empty PF ruleset')
        if pf('-s', 'Tables').stdout.strip():
            raise RuntimeError('PF contains existing tables; inspect before initializing')
        if pf('-sn').stdout.strip() or pf('-s', 'Anchors').stdout.strip():
            raise RuntimeError('PF contains unattached policy; inspect before initializing')
        content = pathlib.Path('/etc/pf.conf').read_text()
        significant = [line.strip() for line in content.splitlines() if line.strip() and not line.lstrip().startswith('#')]
        stock = ['scrub-anchor "com.apple/*"', 'nat-anchor "com.apple/*"', 'rdr-anchor "com.apple/*"',
                 'dummynet-anchor "com.apple/*"', 'anchor "com.apple/*"', 'load anchor "com.apple" from "/etc/pf.anchors/com.apple"']
        if significant != stock:
            raise RuntimeError('Nonstandard /etc/pf.conf; refusing automatic initialization')
        trusted('/etc/pf.conf')
        trusted('/etc/pf.anchors/com.apple')
        apple = [line.strip() for line in pathlib.Path('/etc/pf.anchors/com.apple').read_text().splitlines() if line.strip() and not line.lstrip().startswith('#')]
        if apple != ['anchor "200.AirDrop/*"', 'anchor "250.ApplicationFirewall/*"']:
            raise RuntimeError('Nonstandard Apple anchor; refusing automatic initialization')
        pf('-nf', '/etc/pf.conf')
        pf('-f', '/etc/pf.conf')
    if not root_rules_safe(pf('-sr').stdout):
        raise RuntimeError('Unsupported root PF policy')
    existing = pf('-a', ANCHOR, '-sr').stdout
    if existing.strip() and not anchor_rules_safe(existing, config['uid'], config['owner']):
        raise RuntimeError('Anchor already contains different rules')
    pf('-a', ANCHOR, '-f', '-', input=rules(config['uid']))
    boot = boot_id()
    saved = json.loads(TOKEN.read_text()) if TOKEN.exists() else {}
    if saved.get('boot') != boot:
        result = pf('-E')
        match = re.search(r'Token\s*:\s*(\d+)', result.stdout + result.stderr)
        if not match:
            raise RuntimeError('Unable to retain PF enable reference')
        atomic_json(TOKEN, {'boot': boot, 'token': match[1]})
    check(config)


def remove_policy():
    READY.unlink(missing_ok=True)
    pf('-a', ANCHOR, '-F', 'rules')
    if TOKEN.exists():
        data = json.loads(TOKEN.read_text())
        if data.get('boot') == boot_id() and re.fullmatch(r'\d+', data.get('token', '')):
            pf('-X', data['token'])
        TOKEN.unlink()


def monitor(config):
    READY.unlink(missing_ok=True)
    initialize(config)
    stopping = False
    def stop(signum, frame):
        nonlocal stopping
        stopping = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    last = None
    try:
        while not stopping:
            try:
                check(config)
                atomic_json(READY, {'uid': config['uid'], 'pid': os.getpid(), 'monotonic': time.clock_gettime(time.CLOCK_MONOTONIC_RAW)}, 0o644)
                state = 'protection ready'
            except Exception:
                READY.unlink(missing_ok=True)
                state = 'protection unavailable; console supervisors must stop'
            if state != last:
                print('proxmacs PF: ' + state, flush=True)
                last = state
            time.sleep(1)
    finally:
        READY.unlink(missing_ok=True)
        # Leave rules enabled on monitor failure/stop. Explicit rollback removes them.


if __name__ == '__main__':
    import sys
    if os.geteuid() != 0 or sys.argv[1:] != ['monitor']:
        sys.exit('Root monitor only; use install-console-pf.py for installation/rollback')
    monitor(configuration())
