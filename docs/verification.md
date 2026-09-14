# Bootstrap verification

Local automated validation covers synthetic credential entry through a real
PTY, retained credentials, helper protocol scope, filesystem protections,
noninteractive refusal, shared prerequisites installation options, and real
Git clone/rerun/local-edit preservation.
Run `bash -n bootstrap.sh` and `python3 -m unittest discover -s test -v`.
No live host provisioning or real credential access is part of those tests.

## Fresh Ubuntu smoke test

Use a disposable Ubuntu VPS with working networking and an operator-owned SSH
session. Do not run this flow through an agent-connected terminal.

1. Run the entry command from the README using an account with sudo authority
   (or pass `--prereqs` to install shared host prerequisites only).
   On bare Ubuntu, base packages and shared prerequisites are installed as needed.
2. At the masked prompt, enter a PAT authorized to read the private installer
   repository. Typed characters must not appear on screen.
3. Confirm that the service-selection menu appears. Stop at the menu if this is
   only a bootstrap test; installing an application is a separate validation.
4. Check metadata without displaying the credential:

   ```bash
   sudo stat -c '%U %a %n' /root/.secrets /root/.secrets/gh_pat.txt
   stat -c '%U %a %n' /srv/repos /srv/repos/jamaynor/vps-services
   ```

   Expected: secret directory `root 700`, PAT file `root 600`, source directories
   root-owned and readable, with no group/world write permission.
5. Rerun the same command. Expect a retained-credential status, a clean
   fast-forward checkout update, and the menu without another PAT prompt.

## Failure signals and recovery

- An empty credential stops without creating the PAT file. Rerun to retry.
- Failed authentication must stop before the service menu. Remove only the
  retained PAT file in your own SSH terminal and rerun to replace it.
- Local checkout edits must stop the update without changing those edits.
  Resolve and preserve the work manually before rerunning.
- Unexpected checkout ownership or credential permissions must stop safely.
  Investigate the named path; do not bypass the check to make the test pass.
- Stop rollout if any credential appears in terminal output or logs, or if a
  failed repository update launches the old installer. Revoke a disclosed PAT
  through GitHub and correct the cause before retrying.

The launcher changes package prerequisites, protected credential storage,
root's GitHub credential-helper settings, and the installer checkout. It does
not install a background bootstrap service. Retiring it requires an operator
to review those resources and any other workflows using the retained helper;
there is no automatic destructive uninstall.
