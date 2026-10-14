#!/usr/bin/env python3
"""Exercise the real Swift HTTP/WebSocket server with an isolated authenticated RFB fixture."""
import argparse
import base64
import http.cookiejar
import json
import os
import pathlib
import signal
import socket
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
PASSWORD = 'console-test-login'

class WebSocket:
    def __init__(self, port, cookie='', origin=None):
        self.socket = socket.create_connection(('127.0.0.1', port), timeout=6)
        key = base64.b64encode(os.urandom(16)).decode()
        headers = [f'GET /api/vms/console-test/console/vnc HTTP/1.1', f'Host: 127.0.0.1:{port}',
                   'Connection: Upgrade', 'Upgrade: websocket', 'Sec-WebSocket-Version: 13', f'Sec-WebSocket-Key: {key}']
        if cookie: headers.append('Cookie: '+cookie)
        if origin: headers.append('Origin: '+origin)
        self.socket.sendall(('\r\n'.join(headers)+'\r\n\r\n').encode())
        response = b''
        while not response.endswith(b'\r\n\r\n'):
            response += self.read(1)
        self.status = int(response.split(b' ')[1])

    def read(self, count):
        data = b''
        while len(data) < count:
            chunk = self.socket.recv(count-len(data))
            if not chunk: raise EOFError()
            data += chunk
        return data

    def frame(self):
        first, second = self.read(2)
        length = second & 127
        if length == 126: length = int.from_bytes(self.read(2), 'big')
        elif length == 127: length = int.from_bytes(self.read(8), 'big')
        return first & 15, self.read(length)

    def send(self, data):
        mask = os.urandom(4)
        assert len(data) < 126
        self.socket.sendall(bytes([0x82, 0x80 | len(data)]) + mask + bytes(b ^ mask[i%4] for i,b in enumerate(data)))

    def close(self): self.socket.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=pathlib.Path)
    args = parser.parse_args()
    children = []
    with tempfile.TemporaryDirectory(prefix='proxmacs-console-test-') as tmp:
        root = pathlib.Path(tmp); support = root/'support'; tart = root/'tart'; vm = tart/'vms/console-test'; backups = root/'backups'
        for p in [support/'vms/console-test', vm, backups]: p.mkdir(parents=True)
        for p in [tart, backups]: (p/'.proxmacs-storage').touch()
        with socket.socket() as reserve:
            reserve.bind(('127.0.0.1', 0)); port = reserve.getsockname()[1]
        base = f'http://127.0.0.1:{port}'
        (support/'storage.json').write_text(json.dumps(dict(vms=str(tart), backups=str(backups))))
        (support/'web.json').write_text(json.dumps(dict(enabled=True, port=port, bind='127.0.0.1', tls=False)))
        (vm/'config.json').write_text(json.dumps(dict(os='darwin', cpuCount=2, memorySize=4294967296)))
        (support/'vms/console-test/meta.json').write_text(json.dumps(dict(name='console-test', network={'nat':{}}, autostart=False)))
        record = vm/'.proxmacs-console/session.json'
        (support/'external-vms.json').write_text(json.dumps({'console-test':dict(service='system/dev.proxmacs.fixture', ip='127.0.0.1', diskGB=1, consoleFile=str(record))}))
        env = dict(os.environ, PROXMACS_SUPPORT_DIR=str(support), TART_HOME=str(tart), PROXMACS_CONSOLE_FIXTURE=str(vm))
        subprocess.run([str(args.binary), 'cli', 'web-passwd', '--stdin'], input=PASSWORD+'\n', text=True, capture_output=True, check=True, env=env)
        with (root/'runner.log').open('w') as log:
            children.append(subprocess.Popen([os.sys.executable, str(HERE/'console-runner.py'), '--reader', __import__('pwd').getpwuid(os.getuid()).pw_name,
                                             '--state-dir', str(record.parent), '--', str(HERE/'mock-console-vnc.py'), 'run', 'console-test'], env=env, stdout=log, stderr=log, start_new_session=True))
        with (root/'server.log').open('w') as log:
            children.append(subprocess.Popen([str(args.binary), 'cli', 'serve'], env=env, stdout=log, stderr=log, start_new_session=True))
        jar = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        def request(path, data=None, origin=base):
            headers = {'Content-Type':'application/json'}
            if origin: headers['Origin'] = origin
            req = urllib.request.Request(base+path, data=None if data is None else json.dumps(data).encode(), headers=headers)
            try:
                with opener.open(req, timeout=5) as r: return r.status, r.read(), r.headers
            except urllib.error.HTTPError as e: return e.code, e.read(), e.headers
        try:
            for _ in range(100):
                try:
                    if request('/api/session')[0] in (200,401) and record.exists(): break
                except (OSError, urllib.error.URLError): pass
                time.sleep(0.1)
            else: raise AssertionError('Fixture server failed to start')
            path='/api/vms/console-test/console/session'
            assert request(path,{})[0] == 401
            assert request('/api/login',dict(password=PASSWORD))[0] == 204
            cookie='; '.join(c.name+'='+c.value for c in jar)
            for origin in [None, 'null', 'https://evil.example', base+'/path']:
                assert request(path,{},origin)[0] == 403
            status,data,headers=request(path,{})
            assert status == 200 and json.loads(data)['password'] == 'console-fixture-password'
            assert headers.get('Cache-Control') == 'no-store'
            for cookie_value,origin in [('',base),(cookie,'https://evil.example'),(cookie,None)]:
                ws=WebSocket(port,cookie_value,origin)
                assert ws.status != 101
                ws.close()
            ws=WebSocket(port,cookie,base)
            assert ws.status == 101
            op,greeting=ws.frame();assert op == 2 and greeting == b'RFB 003.008\n'
            ws.send(greeting)
            op,auth=ws.frame();assert op == 2 and auth == b'\x01\x02'
            assert request('/api/logout',{})[0] == 204
            op,_=ws.frame();assert op == 8
            ws.close()
            assert request('/api/login',dict(password=PASSWORD))[0] == 204
            original=record.read_bytes()
            stale=json.loads(original);stale['pid']=2147483647;record.write_text(json.dumps(stale))
            assert request(path,{})[0] == 400
            record.write_bytes(original)
            record.chmod(0o644)
            assert request(path,{})[0] == 400
            record.chmod(0o600)
            children[0].terminate();children[0].wait(timeout=8)
            assert not record.exists()
            assert request(path,{})[0] == 400
            log=(root/'runner.log').read_text()
            assert 'console-fixture-password' not in log and 'vnc://' not in log
            print('PASS: authenticated session, Origin checks, binary bridge, logout disconnect, stale PID, file permissions, credential cleanup and log redaction')
        finally:
            for child in reversed(children):
                if child.poll() is None:
                    child.terminate()
                    try: child.wait(timeout=8)
                    except subprocess.TimeoutExpired: os.killpg(child.pid,signal.SIGKILL);child.wait()

if __name__ == '__main__': main()
