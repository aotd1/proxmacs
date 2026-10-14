#!/usr/bin/env python3
"""Install a dedicated PF anchor, root health monitor and external-console launcher.

Run --check first. Installation requires a remote SSH probe on the same LAN and
verifies IPv4 + IPv6 rejection before enabling launcher support. No VM is restarted.
"""
import argparse
import hashlib
import importlib.util
import ipaddress
import json
import os
import pathlib
import plistlib
import pwd
import re
import shlex
import shutil
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
LABEL = 'org.proxmacs.console-pf'
PLIST = pathlib.Path('/Library/LaunchDaemons') / (LABEL + '.plist')


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


policy = load('console_pf', 'console-pf.py')
launcher_tools = load('console_launcher', 'install-console-launcher.py')


def digest(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def write_root(path, data, mode):
    import tempfile
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.install-')
    try:
        os.fchmod(fd, mode)
        os.fchown(fd, 0, 0)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        os.replace(name, path)
    finally:
        pathlib.Path(name).unlink(missing_ok=True)


def no_active_vnc(uid):
    listing = policy.command(['/bin/ps', '-axo', 'uid=,command=']).stdout
    for line in listing.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0] == str(uid) and '--vnc-experimental' in parts[1]:
            raise RuntimeError('Stop console-enabled VMs before installation or rollback')


def drop_to(account):
    def switch():
        os.setgroups([])
        os.setgid(account.pw_gid)
        os.setuid(account.pw_uid)
    return switch


FIXTURE = '''import socket,selectors,json
selector=selectors.DefaultSelector(); ports={}
for family,addr,key in [(socket.AF_INET,'0.0.0.0','v4'),(socket.AF_INET6,'::','v6')]:
 s=socket.socket(family,socket.SOCK_STREAM)
 if family==socket.AF_INET6: s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
 s.bind((addr,0));s.listen();selector.register(s,selectors.EVENT_READ);ports[key]=s.getsockname()[1]
print(json.dumps(ports),flush=True)
while True:
 for event,mask in selector.select():
  c,addr=event.fileobj.accept();c.close()
'''


def probe_remote(config, address, port, should_connect):
    account = pwd.getpwnam(config['reader'])
    family = '-6' if ':' in address else '-4'
    remote = 'test -x /usr/bin/nc || exit 70; ' + shlex.join(['/usr/bin/nc', family, '-z', '-G', '3', '-w', '3', address, str(port)])
    result = subprocess.run(['/usr/bin/ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', config['probe_ssh'], remote],
                            cwd='/private/tmp', env={'PATH': '/usr/bin:/bin', 'HOME': account.pw_dir},
                            preexec_fn=drop_to(account), capture_output=True, text=True, timeout=15)
    expected = 0 if should_connect else 1
    if result.returncode != expected:
        raise RuntimeError('Remote PF probe failed (expected ' + ('reachable control socket' if should_connect else 'blocked owner socket') + ')')


def verify_network(config):
    import select
    import socket
    # Control sockets prove that SSH and the remote network path really work.
    for username, blocked in [(config['reader'], False), (config['owner'], True)]:
        account = pwd.getpwnam(username)
        process = subprocess.Popen(['/usr/bin/python3', '-I', '-u', '-c', FIXTURE], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, cwd='/private/tmp', preexec_fn=drop_to(account),
                                   env={'PATH': '/usr/bin:/bin', 'HOME': account.pw_dir})
        try:
            if not select.select([process.stdout], [], [], 8)[0]:
                raise RuntimeError('Test socket startup timed out')
            ports = json.loads(process.stdout.readline())
            for key, local, remote in [('v4', '127.0.0.1', config['probe_v4']), ('v6', '::1', config['probe_v6'])]:
                with socket.create_connection((local, ports[key]), timeout=3):
                    pass
                probe_remote(config, remote, ports[key], not blocked)
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
    policy.check(config)
    print('PASS: IPv4/IPv6 loopback works; remote control sockets reachable; Tart-owner sockets blocked.')


def stop_monitor():
    result = subprocess.run(['/bin/launchctl', 'bootout', 'system/' + LABEL], capture_output=True, timeout=15)
    # launchctl can return before the terminated job leaves the service registry.
    for _ in range(20):
        exists = subprocess.run(['/bin/launchctl', 'print', 'system/' + LABEL], capture_output=True, timeout=10)
        if exists.returncode != 0:
            policy.READY.unlink(missing_ok=True)
            return
        time.sleep(0.5)
    raise RuntimeError('Monitor is still loaded; refusing to remove protection (bootout status ' + str(result.returncode) + ')')


def rollback(config):
    no_active_vnc(config['uid'])
    # Refuse to overwrite later administrative edits.
    for key, expected in config['installed_hashes'].items():
        current = digest(key)
        if current != expected and current != digest(config['backups'][key]):
            raise RuntimeError('Installed launcher changed; inspect before rollback')
    for target, saved in config['backups'].items():
        write_root(pathlib.Path(target), pathlib.Path(saved).read_bytes(), 0o755)
    stop_monitor()
    policy.remove_policy()
    PLIST.unlink(missing_ok=True)
    # Keep root-owned config/backups for audit. No global PF disable or flush.
    config['rolled_back'] = True
    policy.atomic_json(policy.CONFIG, config)
    print('Rolled back launcher and removed only the console PF rules/reference. No VM restarted.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--launcher', type=pathlib.Path)
    parser.add_argument('--python', default='/usr/bin/python3')
    parser.add_argument('--owner')
    parser.add_argument('--reader')
    parser.add_argument('--probe-ssh')
    parser.add_argument('--probe-v4')
    parser.add_argument('--probe-v6')
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument('--check', action='store_true')
    actions.add_argument('--verify', action='store_true')
    actions.add_argument('--rollback', action='store_true')
    args = parser.parse_args()
    if args.rollback or args.verify:
        if os.geteuid() != 0:
            parser.error('This operation needs sudo')
        config = policy.configuration()
        if args.rollback:
            rollback(config)
        else:
            policy.check(config); verify_network(config)
        return
    required = ['launcher', 'owner', 'reader', 'probe_ssh', 'probe_v4', 'probe_v6']
    if any(getattr(args, key) is None for key in required):
        parser.error('Installation/check requires --launcher, --owner, --reader, --probe-ssh, --probe-v4 and --probe-v6')
    if not re.fullmatch(r'[a-z_][a-z0-9_-]*', args.owner) or not re.fullmatch(r'[a-z_][a-z0-9_-]*', args.reader):
        parser.error('Invalid account name')
    owner, reader = pwd.getpwnam(args.owner), pwd.getpwnam(args.reader)
    if owner.pw_uid == reader.pw_uid or owner.pw_uid < 500 or reader.pw_uid < 500:
        parser.error('Use separate non-root VM and panel accounts')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', args.probe_ssh):
        parser.error('Use a configured SSH host alias')
    ipaddress.IPv4Address(args.probe_v4)
    ipaddress.IPv6Address(args.probe_v6)
    path = args.launcher
    if not path.is_absolute():
        parser.error('Absolute launcher path required')
    policy.trusted(path)
    if not os.path.isabs(args.python) or not os.access(args.python, os.X_OK):
        parser.error('Absolute Python executable required')
    old = path.read_text()
    runner = path.with_name('console-runner.py')
    if 'console-runner.py' in old:
        original_path = path.with_name(path.name + '.pre-proxmacs-console')
        policy.trusted(original_path)
        if args.check and not os.access(original_path, os.R_OK):
            prefix = launcher_tools.transform('TART_HOME=/placeholder\nexec "$TART_BIN" run ', runner, args.python, args.reader).split('\n')[1]
            if prefix not in old:
                parser.error('Existing launcher is not a recognized supervisor')
            original = old.replace(prefix, 'exec "$TART_BIN" run ')
        else:
            original = original_path.read_text()
        expected = launcher_tools.transform(original, runner, args.python, args.reader)
        if old != expected:
            parser.error('Existing launcher differs from the known pre-PF supervisor; review manually')
    else:
        original = old
    updated = launcher_tools.transform(original, runner, args.python, args.reader, policy.READY)
    policy.command(['/bin/bash', '-n'], input=updated)
    for name in ['console-pf.py', 'console-runner.py']:
        compile((HERE / name).read_text(), name, 'exec')
    no_active_vnc(owner.pw_uid)
    if args.check:
        print('Static prerequisites and launcher syntax passed. Root PF state and network probes still require sudo.')
        print(policy.rules(owner.pw_uid).strip())
        return
    if os.geteuid() != 0:
        parser.error('Run installation with sudo; --check is read-only')
    if policy.BASE.exists():
        previous = policy.configuration()
        inactive = subprocess.run(['/bin/launchctl', 'print', 'system/' + LABEL], capture_output=True, timeout=10).returncode != 0
        same = previous['owner'] == args.owner and previous['reader'] == args.reader
        pristine = all(digest(target) == digest(saved) for target, saved in previous['backups'].items())
        retryable = previous.get('rolled_back') or not previous.get('installed_hashes')
        if not (inactive and same and pristine and retryable and not PLIST.exists() and not policy.READY.exists()):
            parser.error('Active or changed PF installation exists; inspect or roll back first')
        policy.BASE.rename(policy.BASE.with_name(policy.BASE.name + '.previous-' + str(time.time_ns())))
    if PLIST.exists() or policy.pf('-a', policy.ANCHOR, '-sr').stdout.strip():
        parser.error('Existing PF service/anchor was not created by this installation; refusing to overwrite it')
    for target in [path, runner]:
        policy.trusted(target)
    policy.BASE.mkdir(mode=0o755)
    policy.trusted(policy.BASE)
    config = {'uid': owner.pw_uid, 'owner': args.owner, 'reader': args.reader, 'probe_ssh': args.probe_ssh,
              'probe_v4': args.probe_v4, 'probe_v6': args.probe_v6, 'backups': {}, 'installed_hashes': {}}
    installed_launcher = False
    try:
        for target in [path, runner]:
            policy.trusted(target)
            saved = policy.BASE / (target.name + '.before-pf')
            write_root(saved, target.read_bytes(), 0o700)
            config['backups'][str(target)] = str(saved)
        policy.atomic_json(policy.CONFIG, config)
        write_root(policy.BASE / 'console-pf.py', (HERE / 'console-pf.py').read_bytes(), 0o755)
        plist = {'Label': LABEL, 'ProgramArguments': ['/usr/bin/python3', '-I', str(policy.BASE / 'console-pf.py'), 'monitor'],
                 'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10, 'Umask': 0o077,
                 'StandardOutPath': str(policy.BASE / 'monitor.log'), 'StandardErrorPath': str(policy.BASE / 'monitor-error.log')}
        for log in ['monitor.log', 'monitor-error.log']:
            write_root(policy.BASE / log, b'', 0o644)  # Diagnostics contain no VM/VNC credentials.
        write_root(PLIST, plistlib.dumps(plist), 0o644)
        policy.command(['/bin/launchctl', 'bootstrap', 'system', str(PLIST)])
        for _ in range(15):
            if policy.READY.exists():
                break
            time.sleep(1)
        if not policy.READY.exists():
            raise RuntimeError('PF monitor is not ready; inspect its root-owned monitor-error.log')
        policy.check(config)
        verify_network(config)
        write_root(runner, (HERE / 'console-runner.py').read_bytes(), 0o755)
        installed_launcher = True
        write_root(path, updated.encode(), 0o755)
        # Python <=3.9 on macOS has a process-relative time.monotonic(). Verify
        # the actual service interpreter/account can read the shared-clock record.
        subprocess.run([args.python, '-I', '-c',
                        'import runpy,sys; m=runpy.run_path(sys.argv[1]); sys.exit(0 if m["firewall_ready"](sys.argv[2]) else 1)',
                        str(runner), str(policy.READY)], check=True, capture_output=True, text=True, timeout=10,
                       cwd='/private/tmp', preexec_fn=drop_to(owner), env={'PATH': '/usr/bin:/bin', 'HOME': owner.pw_dir})
        config['installed_hashes'] = {str(item): digest(item) for item in [path, runner]}
        policy.atomic_json(policy.CONFIG, config)
        print('PF protection and launcher installed. Console markers unchanged; no VM restarted.')
    except BaseException:
        if installed_launcher:
            for target, saved in config['backups'].items():
                write_root(pathlib.Path(target), pathlib.Path(saved).read_bytes(), 0o755)
        stop_monitor()
        try:
            policy.remove_policy()
        except Exception:
            print('PF cleanup needs inspection; protection was not globally disabled.', file=sys.stderr)
        PLIST.unlink(missing_ok=True)
        diagnostic = policy.BASE / 'monitor-error.log'
        if diagnostic.exists():
            print('\n'.join(diagnostic.read_text(errors='replace').splitlines()[-18:]), file=sys.stderr)
        print('Installation failed. Existing VM launcher restored; diagnostic files retained at ' + str(policy.BASE), file=sys.stderr)
        raise


if __name__ == '__main__':
    main()
