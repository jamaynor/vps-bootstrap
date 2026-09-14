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
        command = f'source {fixture_script}\nREPOSITORY={upstream}\numask 022\nprepare_checkout'
        first = subprocess.run(['bash', '-c', command], text=True, capture_output=True)
        self.assertEqual(first.returncode, 0, first.stderr)
        checkout = self.root / 'srv/repos/jamaynor/vps-services'
        self.assertEqual(checkout.stat().st_mode & 0o777, 0o755)
        self.assertEqual((checkout / 'install.sh').stat().st_mode & 0o777, 0o644)
        second = subprocess.run(['bash', '-c', command], text=True, capture_output=True)
        self.assertEqual(second.returncode, 0, second.stderr)
        (checkout / 'install.sh').write_text('operator edits\n')
        dirty = subprocess.run(['bash', '-c', command], text=True, capture_output=True)
        self.assertNotEqual(dirty.returncode, 0)
        self.assertIn('local changes', dirty.stderr)
        self.assertEqual((checkout / 'install.sh').read_text(), 'operator edits\n')

    def test_full_launcher_reaches_menu_without_exposing_pat(self):
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
        command = (f'source {fixture_script}\nREPOSITORY={upstream}\n'
                   'dpkg-query() { printf "install ok installed\\n"; }\n'
                   'apt-get() { exit 97; }\nmain')
        pid, fd = pty.fork()
        if pid == 0:
            os.execv('/bin/bash', ['bash', '-c', command])
        output = b''
        sent = False
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
                    if b'GitHub PAT (hidden;' in output and not sent:
                        os.write(fd, b'ghp_FAKE_HOST_ONLY\n')
                        sent = True
            else:
                os.kill(pid, 9)
                self.fail('launcher timed out')
            _, status = os.waitpid(pid, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode())
        finally:
            os.close(fd)
        self.assertIn(b'SERVICE_MENU_REACHED', output)
        self.assertNotIn(b'ghp_FAKE_HOST_ONLY', output)
        secret = host_root / '.secrets/gh_pat.txt'
        self.assertEqual(secret.read_text(), 'ghp_FAKE_HOST_ONLY\n')
        self.assertEqual(secret.stat().st_mode & 0o777, 0o600)
        checkout = self.root / 'srv/repos/jamaynor/vps-services'
        self.assertEqual(checkout.stat().st_mode & 0o777, 0o755)
        self.assertEqual((checkout / 'install.sh').stat().st_mode & 0o777, 0o644)
        config = (host_root / '.gitconfig').read_text()
        self.assertNotIn('ghp_FAKE_HOST_ONLY', config)

    def test_checkout_rejects_service_writable_tree_before_git(self):
        checkout = self.root / 'checkout'
        (checkout / '.git').mkdir(parents=True)
        checkout.chmod(0o777)
        result = self.run_shell(f'CHECKOUT={checkout}\ncheck_checkout_tree')
        self.assertNotEqual(result.returncode, 0)

    def test_piped_launcher_reaches_menu_without_exposing_pat(self):
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
        stub = 'dpkg-query() { printf "install ok installed\\n"; }\napt-get() { exit 97; }\n'
        content = SCRIPT.read_text().replace('/root', str(host_root)) \
                                    .replace('/srv', str(self.root / 'srv')) \
                                    .replace('/etc/os-release', str(os_release)) \
                                    .replace('https://github.com/jamaynor/vps-services.git', str(upstream))
        fixture_script.write_text(stub + content)
        pid, fd = pty.fork()
        if pid == 0:
            os.execv('/bin/bash', ['bash', '-c', f'cat {fixture_script} | bash'])
        output = b''
        sent = False
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
        self.assertIn(b'SERVICE_MENU_REACHED', output)
        self.assertNotIn(b'ghp_FAKE_HOST_ONLY', output)
        secret = host_root / '.secrets/gh_pat.txt'
        self.assertEqual(secret.read_text(), 'ghp_FAKE_HOST_ONLY\n')
        self.assertEqual(secret.stat().st_mode & 0o777, 0o600)
        checkout = self.root / 'srv/repos/jamaynor/vps-services'
        self.assertEqual(checkout.stat().st_mode & 0o777, 0o755)
        self.assertEqual((checkout / 'install.sh').stat().st_mode & 0o777, 0o644)

if __name__ == '__main__':
    unittest.main()
