#!/usr/bin/env python3
"""Loopback-only RFB fixture for console tests. Never starts a VM.

Set PROXMACS_CONSOLE_FIXTURE to an isolated directory with config.json.
Imitates Tart's POSIX process lock and VNC startup line. Uses a public test password.
"""
import fcntl
import json
import os
import pathlib
import socket
import struct
import subprocess
import threading
import time

ROOT = pathlib.Path(os.environ['PROXMACS_CONSOLE_FIXTURE'])
PASSWORD = 'console-fixture-password'

def recv(sock, count):
    data = b''
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError()
        data += chunk
    return data


def client(sock, first):
    with (ROOT/'events.jsonl').open('a') as stream:
        stream.write(json.dumps(dict(type='connect'))+'\n')
    try:
        if first:
            def drop_on_request():
                while not (ROOT/'drop-anchor').exists():
                    time.sleep(0.05)
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            threading.Thread(target=drop_on_request, daemon=True).start()
        sock.sendall(b'RFB 003.008\n')
        recv(sock, 12)
        sock.sendall(b'\x01\x02')
        assert recv(sock, 1) == b'\x02'
        challenge = os.urandom(16)
        sock.sendall(challenge)
        key = bytes(int(f'{b:08b}'[::-1], 2) for b in PASSWORD.encode()[:8])
        expected = subprocess.run(['/usr/bin/openssl', 'enc', '-des-ecb', '-K', key.hex(), '-nosalt', '-nopad'], input=challenge, capture_output=True, check=True).stdout
        assert recv(sock, 16) == expected
        sock.sendall(struct.pack('!I', 0))
        recv(sock, 1)
        width, height = 640, 360
        pixel_format = struct.pack('!BBBBHHHBBBxxx', 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
        title = b'Proxmacs console test - keyboard and mouse enabled'
        sock.sendall(struct.pack('!HH', width, height) + pixel_format + struct.pack('!I', len(title)) + title)
        red, green, blue = 40, 150, 210
        sent = False
        while True:
            kind = recv(sock, 1)[0]
            if kind == 0:
                recv(sock, 3)
                pixel_format = recv(sock, 16)
            elif kind == 2:
                count = struct.unpack('!xH', recv(sock, 3))[0]
                recv(sock, count * 4)
            elif kind == 3:
                request = recv(sock, 9)
                if sent and request[0]:
                    continue
                bpp, _, big, _, _, _, _, rshift, gshift, bshift = struct.unpack('!BBBBHHHBBBxxx', pixel_format)
                pixel = ((red << rshift) | (green << gshift) | (blue << bshift)).to_bytes(bpp // 8, 'big' if big else 'little')
                header = struct.pack('!BBHHHHHi', 0, 0, 1, 0, 0, width, height, 0)
                sock.sendall(header + pixel * (width * height))
                sent = True
            elif kind == 4:
                event = recv(sock, 7)
                with (ROOT/'events.jsonl').open('a') as stream:
                    stream.write(json.dumps(dict(type='key', down=event[0], key=struct.unpack('!I', event[3:])[0]))+'\n')
            elif kind == 5:
                event = recv(sock, 5)
                with (ROOT/'events.jsonl').open('a') as stream:
                    stream.write(json.dumps(dict(type='pointer', buttons=event[0], x=int.from_bytes(event[1:3]), y=int.from_bytes(event[3:5])))+'\n')
            elif kind == 6:
                size = struct.unpack('!xxxI', recv(sock, 7))[0]
                recv(sock, size)
            else:
                break
    except (EOFError, OSError, AssertionError):
        pass
    finally:
        sock.close()
        with (ROOT/'events.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(type='disconnect'))+'\n')


with (ROOT/'config.json').open('r+') as lock:
    fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    print(f'VNC server is running at vnc://:{PASSWORD}@127.0.0.1:{listener.getsockname()[1]}', flush=True)
    first = True
    while True:
        connection, _ = listener.accept()
        threading.Thread(target=client, args=(connection, first), daemon=True).start()
        first = False
