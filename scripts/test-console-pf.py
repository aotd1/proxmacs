import contextlib
import importlib.util
import io
import json
import os
import pathlib
import pwd
import signal
import subprocess
import sys
import tempfile
import types
import stat
import time
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


policy = load('console_pf_test', 'console-pf.py')
runner = load('console_runner_test', 'console-runner.py')
installer = load('console_pf_installer_test', 'install-console-pf.py')


class PolicyTests(unittest.TestCase):
    def test_policy_is_uid_specific_and_blocks_only_inbound_syn_off_loopback(self):
        self.assertIn('in quick on ! lo0 proto tcp', policy.rules(503))
        self.assertIn('user = 503 flags S/SA', policy.rules(503))
        self.assertNotIn(' inet ', policy.rules(503))  # Both address families.
        for uid in [0, -1, True, '503']:
            with self.assertRaises(ValueError):
                policy.rules(uid)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS PF parser')
    def test_actual_pf_parser_accepts_rules_and_matches_health_contract(self):
        result = subprocess.run(['/sbin/pfctl', '-nvf', '-'], input=policy.rules(503), capture_output=True, text=True, check=True)
        self.assertTrue(policy.anchor_rules_safe(result.stdout, 503, 'vmowner'))

    def test_earlier_root_pass_is_rejected(self):
        self.assertTrue(policy.root_rules_safe('scrub-anchor "com.apple/*" all fragment reassemble\nanchor "com.apple/*" all\n'))
        for text in ['', 'anchor "other/*" all', 'pass quick all\nanchor "com.apple/*" all', 'anchor "com.apple/*" on lo0 all']:
            self.assertFalse(policy.root_rules_safe(text))

    def test_rules_must_match_exactly(self):
        text = policy.rules(503)
        self.assertTrue(policy.anchor_rules_safe(text, 503, 'vmowner'))
        self.assertTrue(policy.anchor_rules_safe(text.replace('503', 'vmowner'), 503, 'vmowner'))
        for invalid in [text.replace('503', '504'), text.replace('quick ', ''), text + 'pass all\n', text.replace('! lo0', 'en0')]:
            self.assertFalse(policy.anchor_rules_safe(invalid, 503, 'vmowner'))

    def test_skipped_network_interfaces_rejected(self):
        self.assertTrue(policy.interfaces_safe('lo0 (skip)\n  Cleared: never\nen0\n  References: 1\n'))
        self.assertTrue(policy.interfaces_safe('lo0\n  Flags: skip\nen0\n  Flags: none\n'))
        self.assertFalse(policy.interfaces_safe('en0 (skip)\n'))
        self.assertFalse(policy.interfaces_safe('en0\n  Flags: skip\n'))
        self.assertFalse(policy.interfaces_safe(''))

    def test_health_requires_every_condition(self):
        responses = {('-s', 'info'): 'Status: Enabled for 00:10:00\n', ('-sr',): 'anchor "com.apple/*" all\n',
                     ('-a', 'com.apple', '-s', 'Anchors'): '  000.proxmacs-console\n  200.AirDrop\n',
                     ('-a', policy.ANCHOR, '-sr'): policy.rules(503), ('-v', '-s', 'Interfaces'): 'en0\nlo0 (skip)\n'}
        def invoke(*args, **kwargs):
            return subprocess.CompletedProcess(args, 0, responses[args], '')
        with mock.patch.object(policy, 'pf', side_effect=invoke):
            policy.check({'uid': 503, 'owner': 'vmowner'})
            for key in responses:
                original = responses[key]
                responses[key] = ''
                with self.assertRaises(RuntimeError):
                    policy.check({'uid': 503, 'owner': 'vmowner'})
                responses[key] = original
            responses[('-a', 'com.apple', '-s', 'Anchors')] = '000.bypass\n000.proxmacs-console\n'
            with self.assertRaises(RuntimeError):
                policy.check({'uid': 503, 'owner': 'vmowner'})

    def test_rollback_only_releases_own_anchor_and_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            token = pathlib.Path(directory) / 'token.json'
            ready = pathlib.Path(directory) / 'ready.json'
            token.write_text(json.dumps({'boot': 'current', 'token': '12345'}));ready.touch()
            with mock.patch.object(policy, 'TOKEN', token), mock.patch.object(policy, 'READY', ready), mock.patch.object(policy, 'boot_id', return_value='current'), mock.patch.object(policy, 'pf') as pf:
                policy.remove_policy()
                self.assertEqual(pf.call_args_list, [mock.call('-a', policy.ANCHOR, '-F', 'rules'), mock.call('-X', '12345')])
            self.assertFalse(token.exists()); self.assertFalse(ready.exists())

    def test_unprivileged_or_missing_status_cannot_authorize_wildcard(self):
        self.assertFalse(runner.firewall_ready(None))
        self.assertFalse(runner.firewall_ready('relative.json'))
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'ready.json'
            path.write_text(json.dumps({'uid': os.getuid(), 'pid': os.getpid(), 'monotonic': time.monotonic()}))
            self.assertFalse(runner.firewall_ready(path))

    def test_status_requires_fresh_matching_owner_and_live_monitor(self):
        data = {'uid': 503, 'pid': 42, 'monotonic': 100.0}
        directory_info = types.SimpleNamespace(st_mode=stat.S_IFDIR | 0o755, st_uid=0)
        file_info = types.SimpleNamespace(st_mode=stat.S_IFREG | 0o644, st_uid=0, st_size=100)
        class Stream(io.StringIO):
            def fileno(self): return 42
        with mock.patch.object(pathlib.Path, 'lstat', return_value=directory_info), mock.patch.object(runner.os, 'open', return_value=42), mock.patch.object(runner.os, 'fdopen', side_effect=lambda *a: Stream(json.dumps(data))), mock.patch.object(runner.os, 'fstat', return_value=file_info), mock.patch.object(runner.os, 'kill') as kill, mock.patch.object(runner.time, 'monotonic', return_value=101):
            self.assertTrue(runner.firewall_ready('/protected/ready.json', 503))
            self.assertFalse(runner.firewall_ready('/protected/ready.json', 504))
            for timestamp in [95.0, 102.0, float('nan')]:
                data['monotonic'] = timestamp
                self.assertFalse(runner.firewall_ready('/protected/ready.json', 503))
            data['monotonic'] = 100.0
            kill.side_effect = ProcessLookupError
            self.assertFalse(runner.firewall_ready('/protected/ready.json', 503))
            kill.side_effect = PermissionError
            self.assertTrue(runner.firewall_ready('/protected/ready.json', 503))
            file_info.st_mode = stat.S_IFREG | 0o666
            self.assertFalse(runner.firewall_ready('/protected/ready.json', 503))

    def test_startup_without_pf_executes_original_without_vnc(self):
        with tempfile.TemporaryDirectory() as directory:
            args = ['runner', '--reader', pwd.getpwuid(os.getuid()).pw_name, '--state-dir', directory,
                    '--firewall-status', '/nonexistent/ready.json', '--', '/example/tart', 'run', 'test', '--vnc-experimental', '--net-bridged=en0']
            with mock.patch.object(sys, 'argv', args), mock.patch.object(runner.os, 'execv', side_effect=SystemExit) as execute, mock.patch.object(runner.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit):
                    runner.main()
            self.assertEqual(execute.call_args.args[1], ['/example/tart', 'run', 'test', '--net-bridged=en0'])

    def test_lost_pf_kills_child_removes_credentials_and_pauses(self):
        # Exercise the real PTY/supervision path; only firewall/lsof are simulated.
        real_popen = subprocess.Popen
        processes = []
        with tempfile.TemporaryDirectory() as directory:
            state = pathlib.Path(directory) / 'console'
            paused = pathlib.Path(directory) / 'paused'
            published = []
            real_publish = runner.publish
            def publish(*args):
                real_publish(*args);published.append(True)
            def spawn(command, **kwargs):
                child = real_popen([sys.executable, '-u', '-c', 'import time; print("VNC server is running at vnc://:fixture-secret@127.0.0.1:54321"); time.sleep(60)'], **kwargs)
                processes.append(child)
                return child
            args = ['runner', '--reader', pwd.getpwuid(os.getuid()).pw_name, '--state-dir', str(state), '--pause-file', str(paused),
                    '--firewall-status', '/protected/ready.json', '--', '/example/tart', 'run', 'test']
            output = io.StringIO()
            old_signals = {sig: signal.getsignal(sig) for sig in [signal.SIGINT, signal.SIGTERM]}
            try:
                with mock.patch.object(sys, 'argv', args), mock.patch.object(runner, 'firewall_ready', side_effect=lambda *args: not published), mock.patch.object(runner.subprocess, 'Popen', side_effect=spawn), mock.patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'n*:54321\n', '')), mock.patch.object(runner, 'publish', side_effect=publish), contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    self.assertEqual(runner.main(), 1)
                self.assertTrue(published)
                self.assertTrue(paused.exists())
                self.assertFalse((state / 'session.json').exists())
                self.assertEqual(processes[0].returncode, -signal.SIGKILL)
                self.assertNotIn('fixture-secret', output.getvalue())
                self.assertIn('PF protection lost', output.getvalue())
            finally:
                for sig, handler in old_signals.items(): signal.signal(sig, handler)
                for child in processes:
                    if child.poll() is None: child.kill();child.wait()

    def test_probe_ssh_failure_is_not_misreported_as_blocked(self):
        config = {'reader': pwd.getpwuid(os.getuid()).pw_name, 'probe_ssh': 'example'}
        with mock.patch.object(installer.subprocess, 'run', return_value=subprocess.CompletedProcess([], 255, '', 'unreachable')):
            with self.assertRaises(RuntimeError):
                installer.probe_remote(config, '192.0.2.1', 12345, False)


if __name__ == '__main__':
    unittest.main()
