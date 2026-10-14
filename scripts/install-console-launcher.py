#!/usr/bin/env python3
"""Add a console supervisor to an existing root-owned Tart shell launcher.

Does not stop or start any VM. Restart a VM separately after installation.
"""
import argparse
import os
import pathlib
import pwd
import shlex
import shutil
import subprocess
import tempfile


def transform(source, runner, python, reader, firewall_status=None):
    old = 'exec "$TART_BIN" run '
    new = (f'exec {shlex.quote(python)} {shlex.quote(str(runner))} --reader {shlex.quote(reader)} '
           '--state-dir "$TART_HOME/vms/$1/.proxmacs-console" --pause-file "$TART_HOME/vms/$1/.paused" --enable-file "$TART_HOME/vms/$1/.console-enabled" -- "$TART_BIN" run ')
    if 'console-runner.py' in source:
        raise ValueError('Console supervisor already installed; use --rollback before replacing it')
    if old not in source or 'TART_HOME=' not in source:
        raise ValueError('Unrecognized launcher; review it manually before installing a supervisor')
    if firewall_status:
        new = new.replace(' -- "$TART_BIN" run ', f' --firewall-status {shlex.quote(str(firewall_status))} -- "$TART_BIN" run ')
    return source.replace(old, new)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--launcher', type=pathlib.Path, required=True)
    parser.add_argument('--python', required=True)
    parser.add_argument('--reader', default=os.environ.get('SUDO_USER'))
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--rollback', action='store_true')
    args = parser.parse_args()
    path = args.launcher
    if not path.is_absolute() or path.is_symlink() or path.stat().st_uid != 0 or path.stat().st_mode & 0o022:
        parser.error('Launcher must be an absolute root-owned file without group/other write access')
    if path.parent.stat().st_uid != 0 or path.parent.stat().st_mode & 0o022:
        parser.error('Launcher directory must be root-owned and not writable by other accounts')
    if not os.path.isabs(args.python) or not os.access(args.python, os.X_OK):
        parser.error('--python must identify an installed absolute Python executable')
    if not args.reader:
        parser.error('--reader is required')
    pwd.getpwnam(args.reader)
    backup = path.with_name(path.name + '.pre-proxmacs-console')
    runner = path.with_name('console-runner.py')
    source = backup.read_text() if args.rollback else transform(path.read_text(), runner, args.python, args.reader)
    subprocess.run(['/bin/bash', '-n'], input=source, text=True, check=True)
    if args.check:
        print('Launcher syntax and prerequisites validated; no files changed.')
        return
    if os.geteuid() != 0:
        parser.error('Run installation with sudo; --check works without root')
    if not args.rollback:
        if backup.exists():
            parser.error('Backup already exists; inspect it or use --rollback')
        shutil.copy2(path, backup)
        os.chmod(backup, 0o700)
        shutil.copyfile(pathlib.Path(__file__).with_name('console-runner.py'), runner)
        os.chown(runner, 0, 0)
        os.chmod(runner, 0o755)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.launcher-')
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(source)
        os.chown(temporary, 0, 0)
        os.chmod(temporary, 0o755)
        os.replace(temporary, path)
    finally:
        pathlib.Path(temporary).unlink(missing_ok=True)
    print('Launcher updated. No VM was restarted. Backup:', backup)


if __name__ == '__main__':
    main()
