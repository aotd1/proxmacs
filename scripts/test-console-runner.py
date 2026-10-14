import importlib.util
import pathlib
import unittest

HERE = pathlib.Path(__file__).parent

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

runner = load('console_runner', 'console-runner.py')
installer = load('console_installer', 'install-console-launcher.py')

class ConsoleTests(unittest.TestCase):
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
