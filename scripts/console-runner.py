#!/usr/bin/env python3
"""Supervise Tart VNC, redact its URL, and publish a restricted per-boot endpoint.

Run as the VM owner, not root. The original launcher still owns network and keychain setup.
"""
import argparse
import ctypes
import json
import os
import pathlib
import pty
import pwd
import re
import select
import signal
import socket
import stat
import struct
import threading
import time
import subprocess
import sys
import tempfile
import urllib.parse

VNC_LINE = re.compile(r'VNC server is running at (vnc://\S+)')


def endpoint(line, pid):
    match = VNC_LINE.search(line)
    if not match:
        return None
    url = urllib.parse.urlsplit(match[1])
    if url.hostname != '127.0.0.1' or not url.port or not url.password:
        raise ValueError('Invalid console endpoint')
    return dict(pid=pid, port=url.port, password=urllib.parse.unquote(url.password))


def loopback_only(output, port):
    addresses = [line[1:] for line in output.splitlines() if line.startswith('n') and line.endswith(':' + str(port))]
    return bool(addresses) and all(value in ('127.0.0.1:' + str(port), '[::1]:' + str(port)) for value in addresses)



def firewall_ready(path, uid=None):
    """Accept only a fresh root-owned health record in a protected directory."""
    if path is None:
        return False
    try:
        path = pathlib.Path(path)
        if not path.is_absolute():
            return False
        for parent in path.parents:
            info = parent.lstat()
            if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
                return False
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd) as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022 or info.st_size > 1024:
                return False
            data = json.load(stream)
        age = time.clock_gettime(time.CLOCK_MONOTONIC_RAW) - data['monotonic']
        if data['uid'] != (os.getuid() if uid is None else uid) or not 0 <= age < 6 or data['pid'] <= 1:
            return False
        try:
            os.kill(data['pid'], 0)
        except PermissionError:
            pass  # Root monitor is alive, but this account cannot signal it.
        return True
    except (OSError, ValueError, KeyError, TypeError):
        return False


def listener_present(output, port):
    return any(line.startswith('n') and line.endswith(':' + str(port)) for line in output.splitlines())


def protect(path, reader, directory=False):
    os.chmod(path, 0o700 if directory else 0o600)
    subprocess.run(['/bin/chmod', '-N', str(path)], check=True)
    rights = 'list,search,readattr,readextattr,readsecurity' if directory else 'read,readattr,readextattr,readsecurity'
    subprocess.run(['/bin/chmod', '+a', f'user:{reader} allow {rights}', str(path)], check=True)


def publish(directory, reader, record):
    fd, filename = tempfile.mkstemp(prefix='.session-', dir=directory)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(record, stream)
        protect(filename, reader)
        os.replace(filename, directory / 'session.json')
    finally:
        pathlib.Path(filename).unlink(missing_ok=True)


def vnc_response(password, challenge):
    """VNC's bit-reversed DES key, using macOS CommonCrypto without secret argv."""
    key = bytes(int(f'{byte:08b}'[::-1], 2) for byte in password.encode()[:8].ljust(8, b'\0'))
    crypt = ctypes.CDLL('/usr/lib/libSystem.B.dylib').CCCrypt
    crypt.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                      ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                      ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    crypt.restype = ctypes.c_int32
    output = ctypes.create_string_buffer(32)
    written = ctypes.c_size_t()
    if len(challenge) != 16 or crypt(0, 1, 2, key, 8, None, challenge, 16, output, 32, ctypes.byref(written)) != 0 or written.value != 16:
        raise ValueError('VNC authentication unavailable')
    return output.raw[:16]


def initialize_display(sock, password, timeout=15):
    """Activate a shared, passive RFB 3.8 display; do not send guest input."""
    deadline = time.monotonic() + timeout

    def read(count):
        data = bytearray()
        while len(data) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('VNC initialization timed out')
            sock.settimeout(remaining)
            chunk = sock.recv(count - len(data))
            if not chunk:
                raise EOFError('VNC connection closed')
            data.extend(chunk)
        return bytes(data)

    if read(12) != b'RFB 003.008\n':
        raise ValueError('Unsupported VNC protocol')
    sock.sendall(b'RFB 003.008\n')
    if 2 not in read(read(1)[0]):
        raise ValueError('VNC password authentication required')
    sock.sendall(b'\x02')
    sock.sendall(vnc_response(password, read(16)))
    if read(4) != bytes(4):
        raise ValueError('VNC authentication failed')
    sock.sendall(b'\x01')  # Shared: never evict a browser's console.
    header = read(24)
    width, height = struct.unpack('!HH', header[:4])
    name_size = struct.unpack('!I', header[20:24])[0]
    if not width or not height or name_size > 65536:
        raise ValueError('Invalid VNC display')
    read(name_size)
    sock.sendall(bytes(4) + struct.pack('!BBBBHHHBBBxxx', 32, 24, 0, 1, 255, 255, 255, 0, 8, 16))
    # Standard noVNC display encodings only. Do not negotiate clipboard, Fence or
    # continuous-update extensions: this sink neither renders nor requests a stream.
    encodings = [1, 7, 16, 5, 2, 6, 0, -26, -254, -223, -224, -239]
    sock.sendall(struct.pack('!BBH', 2, 0, len(encodings)) +
                 b''.join(struct.pack('!i', value) for value in encodings))
    sock.sendall(struct.pack('!BBHHHH', 3, 0, 0, 0, 1, 1))
    if read(1) != b'\x00':
        raise ValueError('Expected initial framebuffer update')
    read(3)
    # The display is active. The worker drains the remaining response in bounded
    # chunks, then stays idle; no screenshots or guest clipboard data are retained.
    sock.settimeout(1)


class DisplayAnchor:
    """One attempt per Tart boot. Losing the last client must never trigger a retry."""
    def __init__(self, record, directory, reader):
        self.record, self.directory, self.reader = record, directory, reader
        self.lock = threading.Lock()
        self.stopping = threading.Event()
        self.status = 'starting'
        self.published = False
        self.sock = None
        self.thread = threading.Thread(target=self.run, name='vnc-display-anchor', daemon=True)

    def start(self):
        self.thread.start()

    def run(self):
        try:
            with socket.create_connection(('127.0.0.1', self.record['port']), timeout=5) as sock:
                with self.lock:
                    self.sock = sock
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                initialize_display(sock, self.record['password'])
                with self.lock:
                    if not self.stopping.is_set():
                        self.status = 'ready'
                while not self.stopping.is_set():
                    try:
                        if not sock.recv(65536):
                            raise EOFError('VNC anchor disconnected')
                    except socket.timeout:
                        continue  # An idle display is healthy; never reconnect it.
        except Exception:
            pass  # Never log protocol bytes, credentials or exception payloads.
        finally:
            with self.lock:
                self.sock = None
                self.status = 'stopped' if self.stopping.is_set() else 'failed'
                (self.directory / 'session.json').unlink(missing_ok=True)

    def expose(self):
        # Serialize publication and withdrawal so a dead anchor cannot be republished.
        with self.lock:
            if self.status == 'ready' and not self.published and not self.stopping.is_set():
                publish(self.directory, self.reader, self.record)
                self.published = True
                return True
        return False

    def close(self):
        self.stopping.set()
        with self.lock:
            (self.directory / 'session.json').unlink(missing_ok=True)
            if self.sock:
                try:
                    self.sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        self.thread.join(timeout=1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir', type=pathlib.Path, required=True)
    parser.add_argument('--reader', required=True)
    parser.add_argument('--pause-file', type=pathlib.Path)
    parser.add_argument('--enable-file', type=pathlib.Path)
    parser.add_argument('--firewall-status', type=pathlib.Path)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    pwd.getpwnam(args.reader)
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if len(command) < 3 or command[1] != 'run' or not os.path.isabs(command[0]):
        parser.error('Expected an absolute Tart executable followed by run and VM name')
    if args.enable_file and not args.enable_file.exists():
        (args.state_dir / 'session.json').unlink(missing_ok=True)
        os.execv(command[0], command)
    if args.firewall_status:
        for _ in range(30):
            if firewall_ready(args.firewall_status):
                break
            time.sleep(0.5)  # Allow the independent system PF job to become ready at boot.
    if args.firewall_status and not firewall_ready(args.firewall_status):
        (args.state_dir / 'session.json').unlink(missing_ok=True)
        print('proxmacs: PF protection unavailable; starting VM without console', flush=True)
        os.execv(command[0], [item for item in command if item != '--vnc-experimental'])
    if '--vnc' in command:
        parser.error('Guest Screen Sharing cannot be combined with the graphical console')
    if '--vnc-experimental' not in command:
        command.append('--vnc-experimental')
    if '--no-graphics' not in command:
        command.append('--no-graphics')
    directory = args.state_dir
    if directory.is_symlink():
        parser.error('Console state directory cannot be a symlink')
    directory.mkdir(mode=0o700, parents=False, exist_ok=True)
    if directory.stat().st_uid != os.getuid():
        parser.error('Console state directory must belong to the VM owner')
    protect(directory, args.reader, directory=True)
    state = directory / 'session.json'
    state.unlink(missing_ok=True)
    # A PTY makes Swift stdout line-buffered, so the endpoint is available immediately.
    master, slave = pty.openpty()
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    stopping = threading.Event()
    def forward_signal(signum, frame):
        stopping.set()
        state.unlink(missing_ok=True)
        if child.poll() is None:
            child.send_signal(signum)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, forward_signal)
    buffer = b''
    unsafe = False
    protection_lost = False
    anchor = None
    anchor_reported = False
    try:
        while True:
            if args.firewall_status and not firewall_ready(args.firewall_status):
                protection_lost = True
                raise RuntimeError('PF protection lost')
            if anchor and not stopping.is_set() and child.poll() is None:
                if anchor.expose():
                    print('proxmacs: graphical console ready; persistent display connected (credentials redacted)', flush=True)
                if anchor.status == 'failed' and not anchor_reported:
                    anchor_reported = True
                    print('proxmacs: console unavailable; persistent display disconnected; VM kept running; console recovery requires a planned VM restart', flush=True)
            readable, _, _ = select.select([master], [], [], 0.5)
            if not readable:
                if child.poll() is not None:
                    break
                continue
            try:
                chunk = os.read(master, 16384)
            except OSError:
                break
            if not chunk:
                break
            buffer += chunk
            while b'\n' in buffer:
                raw, buffer = buffer.split(b'\n', 1)
                line = raw.decode('utf-8', errors='replace').rstrip('\r')
                record = endpoint(line, child.pid)
                if record:
                    if anchor or stopping.is_set():
                        continue  # A repeated banner must not reconnect a failed anchor.
                    listeners = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(child.pid), '-iTCP', '-sTCP:LISTEN', '-Fn'], capture_output=True, text=True, check=True, timeout=5)
                    protected = firewall_ready(args.firewall_status) if args.firewall_status else loopback_only(listeners.stdout, record['port'])
                    if not listener_present(listeners.stdout, record['port']) or not protected:
                        # Wildcard sockets require the continuously monitored root PF policy.
                        unsafe = True
                        raise RuntimeError('Console listener is not restricted to loopback')
                    anchor = DisplayAnchor(record, directory, args.reader)
                    anchor.start()
                elif 'vnc://' not in line.lower():
                    print(line, flush=True)
            if len(buffer) > 65536:
                buffer = b''  # Never forward an unbounded or incomplete credential-bearing line.
        return child.wait()
    except Exception:
        state.unlink(missing_ok=True)
        if args.pause_file:
            try:
                args.pause_file.touch(mode=0o660)  # Prevent a KeepAlive restart loop after unsafe console startup.
            except OSError:
                print('proxmacs: unable to pause the system launcher', file=sys.stderr)
        print('proxmacs: console supervisor failed' + (' (PF protection lost)' if protection_lost else ' (unprotected listener)' if unsafe else ''), file=sys.stderr)
        if child.poll() is None:
            if protection_lost:
                child.kill()  # Do not leave raw VNC alive while waiting for guest shutdown.
            else:
                child.terminate()
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        return 1
    finally:
        state.unlink(missing_ok=True)
        if anchor:
            anchor.close()
        os.close(master)


if __name__ == '__main__':
    sys.exit(main())
