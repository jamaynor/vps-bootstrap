"""Credential tests use synthetic values and temporary paths, never host secrets."""
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'bootstrap.sh'
CHECK_PREREQS_SCRIPT = Path(__file__).resolve().parents[1] / 'check-prereqs.sh'

class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.secret_dir = self.root / 'secrets'
        self.prefix = f'''source {SCRIPT}
SECRET_DIR={self.secret_dir}
SECRET_FILE=$SECRET_DIR/gh_pat.txt
CREDENTIAL_FILE=$SECRET_DIR/git-credential-vps
'''

    def tearDown(self):
        self.temp.cleanup()

    def run_shell(self, body, **kwargs):
        return subprocess.run(['bash', '-c', self.prefix + body], text=True, capture_output=True, **kwargs)

    def retained(self, mode=0o600):
        self.secret_dir.mkdir(mode=0o700)
        secret = self.secret_dir / 'gh_pat.txt'
        secret.write_text('ghp_SYNTHETIC_TEST_ONLY\n')
        secret.chmod(mode)
        return secret

    def test_reuses_pat_and_does_not_print_it(self):
        secret = self.retained()
        result = self.run_shell('install_credential')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('ghp_SYNTHETIC_TEST_ONLY', result.stdout + result.stderr)
        self.assertEqual(secret.read_text(), 'ghp_SYNTHETIC_TEST_ONLY\n')
        self.assertEqual(secret.stat().st_mode & 0o777, 0o600)

    def test_rejects_readable_secret(self):
        self.retained(0o644)
        self.assertNotEqual(self.run_shell('install_credential').returncode, 0)

    def test_rejects_symlink_secret(self):
        self.secret_dir.mkdir(mode=0o700)
        target = self.root / 'untouched'
        target.write_text('unchanged')
        (self.secret_dir / 'gh_pat.txt').symlink_to(target)
        self.assertNotEqual(self.run_shell('install_credential').returncode, 0)
        self.assertEqual(target.read_text(), 'unchanged')

    def test_rejects_hardlinked_secret(self):
        secret = self.retained()
        os.link(secret, self.root / 'other')
        self.assertNotEqual(self.run_shell('install_credential').returncode, 0)

    def test_git_credential_protocol_scopes_secret(self):
        self.retained()
        self.assertEqual(self.run_shell('install_credential').returncode, 0)
        helper = self.secret_dir / 'git-credential-vps'
        # Relocate the generated helper into this isolated fixture only.
        helper.write_text(helper.read_text().replace('/root/.secrets', str(self.secret_dir)))
        for protocol, host, path, permitted in [
            ('https', 'github.com', 'jamaynor/vps-services.git', True),
            ('http', 'github.com', 'jamaynor/vps-services.git', False),
            ('https', 'github.com.evil.test', 'jamaynor/vps-services.git', False),
            ('https', 'github.com', 'another-owner/repo.git', False),
            ('https', 'github.com', '', False),
        ]:
            with self.subTest(protocol=protocol, host=host, path=path):
                query = f'protocol={protocol}\nhost={host}\npath={path}\n\n'
                result = subprocess.run([str(helper), 'get'], input=query, text=True, capture_output=True)
                self.assertEqual('ghp_SYNTHETIC_TEST_ONLY' in result.stdout, permitted)
                self.assertNotIn('ghp_SYNTHETIC_TEST_ONLY', result.stderr)
        result = subprocess.run([str(helper), 'store'], input='password=ignored\n\n', text=True, capture_output=True)
        self.assertEqual(result.stdout, '')

    def prompt(self, value):
        self.secret_dir.mkdir(mode=0o700)
        pid, fd = pty.fork()
        if pid == 0:
            os.execv('/bin/bash', ['bash', '-x', '-c', self.prefix + 'prompt_pat'])
        output = b''
        sent = False
        directory_sent = False
        deadline = time.monotonic() + 5
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], .1)[0]:
                    try:
                        chunk = os.read(fd, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
                    if b'Directory for VPS operations tools' in output and not directory_sent:
                        os.write(fd, f'{self.root}/root/custom tools\n'.encode())
                        directory_sent = True
                    if b'GitHub PAT (hidden;' in output and not sent:
                        os.write(fd, value)
                        sent = True
            else:
                os.kill(pid, 9)
                self.fail('prompt timed out')
            _, status = os.waitpid(pid, 0)
            return os.waitstatus_to_exitcode(status), output.decode()
        finally:
            os.close(fd)

    def test_ssh_prompt_masks_pat_even_when_tracing_inherited(self):
        status, output = self.prompt(b'ghp_FAKE_TERMINAL_ONLY\n')
        self.assertEqual(status, 0, output)
        self.assertNotIn('ghp_FAKE_TERMINAL_ONLY', output)
        self.assertEqual((self.secret_dir / 'gh_pat.txt').read_text(), 'ghp_FAKE_TERMINAL_ONLY\n')

    def test_empty_prompt_saves_nothing(self):
        status, _ = self.prompt(b'\n')
        self.assertNotEqual(status, 0)
        self.assertFalse((self.secret_dir / 'gh_pat.txt').exists())

    def test_noninteractive_main_refuses_before_writing(self):
        result = subprocess.run(['bash', str(SCRIPT)], stdin=subprocess.DEVNULL, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('own SSH terminal', result.stderr)

    def test_real_checkout_clone_rerun_and_dirty_refusal(self):
        upstream = self.root / 'upstream'
        upstream.mkdir()
        git_env = {'PATH': '/usr/bin:/bin', 'HOME': str(self.root),
                   'GIT_CONFIG_NOSYSTEM': '1'}
        def git(*args):
            return subprocess.run(['git', *args], env=git_env, check=True,
                                  text=True, capture_output=True)
        git('init', '-b', 'main', str(upstream))
        (upstream / 'install.sh').write_text('#!/bin/bash\necho menu\n')
        git('-C', str(upstream), 'add', 'install.sh')
        git('-C', str(upstream), '-c', 'user.name=Test',
            '-c', 'user.email=test@example.invalid', 'commit', '-m', 'fixture')
        fixture_script = self.root / 'fixture-bootstrap.sh'
        # Relocate every host path before invoking the real checkout functions.
        fixture_script.write_text(SCRIPT.read_text().replace('/root', str(self.root / 'root'))
                                  .replace('/srv', str(self.root / 'srv')))
        (self.root / 'root').mkdir()
        command = f'source {fixture_script}\nREPOSITORY={upstream}\nCHECKOUT="{self.root}/root/custom tools"\nprepare_checkout'
        first = subprocess.run(['bash', '-c', command], text=True, capture_output=True)
        self.assertEqual(first.returncode, 0, first.stderr)
        checkout = self.root / 'root/custom tools'
        self.assertEqual(checkout.stat().st_mode & 0o777, 0o700)
        self.assertEqual((checkout / 'install.sh').stat().st_mode & 0o777, 0o600)
        second = subprocess.run(['bash', '-c', command], text=True, capture_output=True)
        self.assertEqual(second.returncode, 0, second.stderr)
        (checkout / 'install.sh').write_text('operator edits\n')
        dirty = subprocess.run(['bash', '-c', command], text=True, capture_output=True)
        self.assertNotEqual(dirty.returncode, 0)
        self.assertIn('local changes', dirty.stderr)
        self.assertEqual((checkout / 'install.sh').read_text(), 'operator edits\n')

    def test_full_launcher_installs_operations_and_exits_without_exposing_pat(self):
        upstream = self.root / 'upstream'
        upstream.mkdir()
        git_env = {'PATH': '/usr/bin:/bin', 'HOME': str(self.root),
                   'GIT_CONFIG_NOSYSTEM': '1'}
        def git(*args):
            subprocess.run(['git', *args], env=git_env, check=True, capture_output=True)
        git('init', '-b', 'main', str(upstream))
        lock = self.root / 'root/.vps-bootstrap.lock'
        (upstream / 'install.sh').write_text(
            f'#!/bin/bash\nif flock -n {lock} true; then exit 91; fi\n'
            '[[ $PATH == /usr/local/sbin:/usr/local/bin:* ]] || exit 92\n'
            'printf "SERVICE_MENU_REACHED\\n"\n')
        git('-C', str(upstream), 'add', 'install.sh')
        git('-C', str(upstream), '-c', 'user.name=Test',
            '-c', 'user.email=test@example.invalid', 'commit', '-m', 'fixture')
        fixture_script = self.root / 'fixture-bootstrap.sh'
        host_root = self.root / 'root'
        host_root.mkdir()
        os_release = self.root / 'os-release'
        os_release.write_text('ID=ubuntu\n')
        fixture_script.write_text(SCRIPT.read_text().replace('/root', str(host_root))
                                  .replace('/srv', str(self.root / 'srv'))
                                  .replace('/etc/os-release', str(os_release)))
        # Stub only package status; real Git, filesystem, credential prompt, lock,
        # clean environment and exec handoff run in the relocated fixture.
        stub = ('dpkg-query() { printf "install ok installed\\n"; }\n'
                'apt-get() { exit 97; }\n'
                'install_shared_prerequisites() { :; }\n'
                'node() { printf "v22.0.0\\n"; }\n'
                'npm() { :; }\n'
                'curl() { :; }\n'
                'caddy() { :; }\n'
                'gh() { :; }\n'
                'tsc() { :; }\n'
                'claude() { :; }\n'
                'codex() { :; }\n'
                'copilot() { :; }\n'
                'agy() { :; }\n')
        command = f'source {fixture_script}\nREPOSITORY={upstream}\n{stub}main'
        pid, fd = pty.fork()
        if pid == 0:
            os.execv('/bin/bash', ['bash', '-c', command])
        output = b''
        sent = False
        directory_sent = False
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], .1)[0]:
                    try:
                        chunk = os.read(fd, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
                    if b'Directory for VPS operations tools' in output and not directory_sent:
                        os.write(fd, f'{self.root}/root/custom tools\n'.encode())
                        directory_sent = True
                    if b'GitHub PAT (hidden;' in output and not sent:
                        os.write(fd, b'ghp_FAKE_HOST_ONLY\n')
                        sent = True
            else:
                os.kill(pid, 9)
                self.fail(f'launcher timed out, output={output!r}')
            _, status = os.waitpid(pid, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode())
        finally:
            os.close(fd)
        self.assertNotIn(b'SERVICE_MENU_REACHED', output)
        self.assertIn(b'Bootstrap complete.', output)
        self.assertNotIn(b'ghp_FAKE_HOST_ONLY', output)
        secret = host_root / '.secrets/gh_pat.txt'
        self.assertEqual(secret.read_text(), 'ghp_FAKE_HOST_ONLY\n')
        self.assertEqual(secret.stat().st_mode & 0o777, 0o600)
        checkout = self.root / 'root/custom tools'
        self.assertEqual(checkout.stat().st_mode & 0o777, 0o700)
        self.assertEqual((checkout / 'install.sh').stat().st_mode & 0o777, 0o600)
        config = (host_root / '.gitconfig').read_text()
        self.assertNotIn('ghp_FAKE_HOST_ONLY', config)

    def test_checkout_rejects_service_writable_tree_before_git(self):
        checkout = self.root / 'checkout'
        (checkout / '.git').mkdir(parents=True)
        checkout.chmod(0o777)
        result = self.run_shell(f'CHECKOUT={checkout}\ncheck_checkout_tree')
        self.assertNotEqual(result.returncode, 0)

    def test_checkout_rejects_invalid_destinations_before_git(self):
        for path in ['', 'relative', '/roor/tools', '/srv/tools', '/root',
                     '/root/../tmp/tools', '/root/./tools', '/root//tools',
                     '/root/tools/', '/root/tools\nextra']:
            with self.subTest(path=path):
                import shlex
                result = self.run_shell(
                    f'CHECKOUT={shlex.quote(path)}\n'
                    'trusted_git() { echo UNEXPECTED_GIT; exit 99; }\n'
                    'prepare_checkout')
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('UNEXPECTED_GIT', result.stdout)

    def test_checkout_rejects_symlink_or_writable_parent(self):
        host_root = self.root / 'root'
        host_root.mkdir()
        target = self.root / 'target'
        target.mkdir()
        parent = host_root / 'unsafe'
        script = self.root / 'fixture.sh'
        script.write_text(SCRIPT.read_text().replace('/root', str(host_root)))
        for symlink in [True, False]:
            with self.subTest(symlink=symlink):
                if symlink:
                    parent.symlink_to(target, target_is_directory=True)
                else:
                    parent.unlink()
                    parent.mkdir(mode=0o777)
                    parent.chmod(0o777)
                result = subprocess.run(['bash', '-c',
                    f'source {script}\nCHECKOUT={parent}/tools\n'
                    'trusted_git() { echo UNEXPECTED_GIT; exit 99; }\nprepare_checkout'],
                    text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('UNEXPECTED_GIT', result.stdout)
                self.assertFalse((target / 'tools').exists())

    def test_piped_launcher_installs_operations_and_exits_without_exposing_pat(self):
        upstream = self.root / 'upstream'
        upstream.mkdir()
        git_env = {'PATH': '/usr/bin:/bin', 'HOME': str(self.root),
                   'GIT_CONFIG_NOSYSTEM': '1'}
        def git(*args):
            subprocess.run(['git', *args], env=git_env, check=True, capture_output=True)
        git('init', '-b', 'main', str(upstream))
        lock = self.root / 'root/.vps-bootstrap.lock'
        (upstream / 'install.sh').write_text(
            f'#!/bin/bash\nif flock -n {lock} true; then exit 91; fi\n'
            '[[ $PATH == /usr/local/sbin:/usr/local/bin:* ]] || exit 92\n'
            'printf "SERVICE_MENU_REACHED\\n"\n')
        git('-C', str(upstream), 'add', 'install.sh')
        git('-C', str(upstream), '-c', 'user.name=Test',
            '-c', 'user.email=test@example.invalid', 'commit', '-m', 'fixture')
        fixture_script = self.root / 'fixture-bootstrap.sh'
        host_root = self.root / 'root'
        host_root.mkdir()
        os_release = self.root / 'os-release'
        os_release.write_text('ID=ubuntu\n')
        stub = ('dpkg-query() { printf "install ok installed\\n"; }\n'
                'apt-get() { exit 97; }\n'
                'install_shared_prerequisites() { :; }\n'
                'node() { printf "v22.0.0\\n"; }\n'
                'npm() { :; }\n'
                'curl() { :; }\n'
                'caddy() { :; }\n'
                'gh() { :; }\n'
                'tsc() { :; }\n'
                'claude() { :; }\n'
                'codex() { :; }\n'
                'copilot() { :; }\n'
                'agy() { :; }\n')
        content = SCRIPT.read_text().replace('/root', str(host_root)) \
                                    .replace('/srv', str(self.root / 'srv')) \
                                    .replace('/etc/os-release', str(os_release)) \
                                    .replace('https://github.com/jamaynor/vps-operations.git', str(upstream))
        fixture_script.write_text(content.replace('if [[ ${#BASH_SOURCE[@]}', stub + '\nif [[ ${#BASH_SOURCE[@]}'))
        pid, fd = pty.fork()
        if pid == 0:
            os.execv('/bin/bash', ['bash', '-c', f'cat {fixture_script} | bash'])
        output = b''
        sent = False
        directory_sent = False
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], .1)[0]:
                    try:
                        chunk = os.read(fd, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
                    if b'Directory for VPS operations tools' in output and not directory_sent:
                        os.write(fd, f'{self.root}/root/custom tools\n'.encode())
                        directory_sent = True
                    if b'GitHub PAT (hidden;' in output and not sent:
                        os.write(fd, b'ghp_FAKE_HOST_ONLY\n')
                        sent = True
            else:
                os.kill(pid, 9)
                self.fail('piped launcher timed out')
            _, status = os.waitpid(pid, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode())
        finally:
            os.close(fd)
        self.assertNotIn(b'SERVICE_MENU_REACHED', output)
        self.assertIn(b'Bootstrap complete.', output)
        self.assertNotIn(b'ghp_FAKE_HOST_ONLY', output)
        secret = host_root / '.secrets/gh_pat.txt'
        self.assertEqual(secret.read_text(), 'ghp_FAKE_HOST_ONLY\n')
        self.assertEqual(secret.stat().st_mode & 0o777, 0o600)
        checkout = self.root / 'root/custom tools'
        self.assertEqual(checkout.stat().st_mode & 0o777, 0o700)
        self.assertEqual((checkout / 'install.sh').stat().st_mode & 0o777, 0o600)

    def test_help_flag_displays_usage(self):
        for flag in ['-h', '--help']:
            with self.subTest(flag=flag):
                result = subprocess.run(['bash', str(SCRIPT), flag], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0)
                self.assertIn('Usage: bootstrap.sh', result.stdout)
                self.assertIn('--prereqs', result.stdout)

    def test_rejects_unknown_argument(self):
        result = subprocess.run(['bash', str(SCRIPT), '--unknown-flag'], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unknown argument', result.stderr)

    def test_prereqs_only_flag_installs_and_exits(self):
        host_root = self.root / 'root'
        host_root.mkdir()
        os_release = self.root / 'os-release'
        os_release.write_text('ID=ubuntu\n')
        fixture_script = self.root / 'fixture-bootstrap.sh'
        content = SCRIPT.read_text().replace('/root', str(host_root)) \
                                    .replace('/etc/os-release', str(os_release))
        stub = ('dpkg-query() { printf "install ok installed\\n"; }\n'
                'apt-get() { exit 97; }\n'
                'install_shared_prerequisites() { :; }\n'
                'node() { printf "v22.0.0\\n"; }\n'
                'npm() { :; }\n'
                'curl() { :; }\n'
                'claude() { :; }\n'
                'codex() { :; }\n'
                'copilot() { :; }\n'
                'agy() { :; }\n'
                'tsc() { :; }\n')
        fixture_script.write_text(content.replace('if [[ ${#BASH_SOURCE[@]}', stub + '\nif [[ ${#BASH_SOURCE[@]}'))

        for flag in ['--prereqs', '--shared-prereqs', '--prerequisites']:
            with self.subTest(flag=flag):
                result = subprocess.run(['bash', str(fixture_script), flag],
                                        stdin=subprocess.DEVNULL, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('shared prerequisites installed successfully', result.stdout)
                self.assertFalse((host_root / '.secrets').exists())

    def test_check_flag_displays_status_and_exits(self):
        for flag in ['--check', '--status']:
            with self.subTest(flag=flag):
                result = subprocess.run(['bash', str(SCRIPT), flag], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0)
                self.assertIn('Shared Prerequisites Status', result.stdout)

    def test_check_prereqs_script_displays_status_flag(self):
        for flag in ['--check', '--status', '-c']:
            with self.subTest(flag=flag):
                result = subprocess.run(['bash', str(CHECK_PREREQS_SCRIPT), flag],
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0)
                self.assertIn('VPS Shared Prerequisites Status', result.stdout)

    def test_check_prereqs_script_quit_exits_cleanly(self):
        pid, fd = pty.fork()
        if pid == 0:
            os.execv('/bin/bash', ['bash', str(CHECK_PREREQS_SCRIPT)])
        output = b''
        sent = False
        directory_sent = False
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], .1)[0]:
                    try:
                        chunk = os.read(fd, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
                    if b'Select [' in output and not sent:
                        if b'3) Exit' in output:
                            os.write(fd, b'3\n')
                        else:
                            os.write(fd, b'2\n')
                        sent = True
            else:
                os.kill(pid, 9)
                self.fail('check-prereqs prompt timed out')
            _, status = os.waitpid(pid, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode())
        finally:
            os.close(fd)
        self.assertIn(b'Exiting.', output)

if __name__ == '__main__':
    unittest.main()
