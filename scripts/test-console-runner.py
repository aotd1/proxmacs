import importlib.util
import pathlib
import socket
import struct
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

HERE = pathlib.Path(__file__).parent

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

runner = load('console_runner', 'console-runner.py')
installer = load('console_installer', 'install-console-launcher.py')

class ConsoleTests(unittest.TestCase):
    def test_rfb_requires_password_and_valid_bounded_server_init(self):
        def run_reply(reply, expected):
            client, server = socket.socketpair()
            try:
                server.sendall(reply)
                with self.assertRaises(expected):
                    runner.initialize_display(client, 'public-test', timeout=0.1)
            finally:
                client.close(); server.close()
        run_reply(b'RFB 003.003\n', ValueError)
        run_reply(b'RFB 003.008\n\x01\x01', ValueError)
        run_reply(b'RFB 003.008\n\x01\x02' + bytes(16) + b'\0\0\0\1', ValueError)
        init=struct.pack('!HH', 640, 360)+bytes(16)+struct.pack('!I', 65537)
        run_reply(b'RFB 003.008\n\x01\x02' + bytes(20) + init, ValueError)
        run_reply(b'RFB ', (TimeoutError, socket.timeout))  # Python 3.9 has a separate socket.timeout type.

    def test_anchor_waits_for_graphics_then_withdraws_without_reconnecting(self):
        with tempfile.TemporaryDirectory() as tmp, socket.socket() as listener:
            directory=pathlib.Path(tmp)
            listener.bind(('127.0.0.1', 0)); listener.listen(); listener.settimeout(2)
            initialized=threading.Event(); proceed=threading.Event()
            def initialize(sock, password):
                initialized.set()
                self.assertTrue(proceed.wait(2))
            def publish(directory, reader, record):
                (directory/'session.json').write_text('public fixture')
            with patch.object(runner, 'initialize_display', initialize), patch.object(runner, 'publish', publish):
                anchor=runner.DisplayAnchor(dict(port=listener.getsockname()[1], password='public'), directory, 'fixture')
                anchor.start()
                connection, _=listener.accept()
                try:
                    self.assertTrue(initialized.wait(2))
                    self.assertFalse(anchor.expose())
                    self.assertFalse((directory/'session.json').exists())
                    proceed.set()
                    for _ in range(100):
                        if anchor.expose(): break
                        time.sleep(0.01)
                    self.assertTrue((directory/'session.json').exists())
                    connection.shutdown(socket.SHUT_RDWR)
                    anchor.thread.join(2)
                    self.assertEqual(anchor.status, 'failed')
                    self.assertFalse((directory/'session.json').exists())
                    self.assertFalse(anchor.expose())
                    listener.settimeout(0.1)
                    with self.assertRaises(socket.timeout): listener.accept()
                finally:
                    proceed.set(); connection.close(); anchor.close()

    def test_endpoint_keeps_credentials_out_of_url_contract(self):
        record = runner.endpoint('VNC server is running at vnc://:test%2Bpassword@127.0.0.1:54321', 42)
        self.assertEqual(record, dict(pid=42, port=54321, password='test+password'))
        self.assertIsNone(runner.endpoint('VM started', 42))
        with self.assertRaises(ValueError):
            runner.endpoint('VNC server is running at vnc://:test@192.0.2.1:5900', 42)

    def test_listener_must_be_exclusively_loopback(self):
        self.assertTrue(runner.loopback_only('p42\nn127.0.0.1:54321\nn[::1]:54321\n', 54321))
        for output in ['n*:54321', 'n0.0.0.0:54321', 'n[::]:54321', 'n127.0.0.1:54321\nn*:54321', '']:
            self.assertFalse(runner.loopback_only(output, 54321))

    def test_launcher_preserves_existing_vm_flags_and_safely_quotes_paths(self):
        original = 'export TART_HOME=/example\nexec "$TART_BIN" run "$1" --net-bridged=vlan0 --no-clipboard\n'
        updated = installer.transform(original, '/Library/Application Support/Console/console-runner.py', '/usr/bin/python3', 'operator')
        self.assertIn('--net-bridged=vlan0 --no-clipboard', updated)
        self.assertIn("'/Library/Application Support/Console/console-runner.py'", updated)
        self.assertIn('--enable-file "$TART_HOME/vms/$1/.console-enabled"', updated)
        self.assertIn('--state-dir "$TART_HOME/vms/$1/.proxmacs-console"', updated)
        with self.assertRaises(ValueError):
            installer.transform(updated, '/example/console-runner.py', '/usr/bin/python3', 'operator')
        with self.assertRaises(ValueError):
            installer.transform('unknown launcher', '/example/console-runner.py', '/usr/bin/python3', 'operator')

if __name__ == '__main__':
    unittest.main()
