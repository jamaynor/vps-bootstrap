# Bootstrap verification

Local automated validation covers synthetic credential entry through a real
PTY, retained credentials, helper protocol scope, filesystem protections,
noninteractive refusal, shared prerequisites installation options, and real
Git clone/rerun/local-edit preservation.
Run `bash -n bootstrap.sh && bash -n check-prereqs.sh` and `python3 -m unittest discover -s test -v`.
No live host provisioning or real credential access is part of those tests.

## Fresh Ubuntu smoke test

Use a disposable Ubuntu VPS with working networking and an operator-owned SSH
session. Do not run this flow through an agent-connected terminal.

1. Run the entry command from the README using an account with sudo authority
   (or pass `--prereqs` to install shared host prerequisites only, or run
   `./check-prereqs.sh` to see the status checklist with green checks and menu).
   To verify that all shared prerequisite commands and binaries are present in PATH:

   ```bash
   ./check-prereqs.sh --check
   ```

   Or via loop:

   ```bash
   for cmd in git curl gpg ufw python3 python node npm caddy gh tsc claude codex copilot agy; do
       command -v "$cmd" >/dev/null 2>&1 && echo "✓ $cmd: $(command -v "$cmd")" || echo "✗ $cmd missing"
   done
   ```
2. Enter a chosen absolute checkout directory beneath `/root`. At the masked
   prompt, enter a PAT authorized to read `jamaynor/vps-operations`. PAT
   characters must not appear on screen.
3. Confirm the operations repository was installed in the directory you entered
   and bootstrap exited successfully. No service menu or additional install
   prompt should appear, and no checkout script should execute.
4. Check metadata without displaying the credential:

   ```bash
   sudo stat -c '%U %a %n' /root/.secrets /root/.secrets/gh_pat.txt
   ```

   Expected: secret directory `root 700`, PAT file `root 600`. Inspect the chosen
   checkout separately: it must be owned by root with mode `700`.
5. Rerun the same command. Expect a retained-credential status, a clean
   fast-forward checkout update at the entered directory, and successful exit
   without another PAT prompt or any service-selection menu.

## Failure signals and recovery

- An empty credential stops without creating the PAT file. Rerun to retry.
- Failed authentication must stop before checkout completion. Remove only the
  retained PAT file in your own SSH terminal and rerun to replace it.
- Local checkout edits must stop the update without changing those edits.
  Resolve and preserve the work manually before rerunning.
- Unexpected checkout ownership or credential permissions must stop safely.
  Investigate the named path; do not bypass the check to make the test pass.
- Stop rollout if any credential appears in terminal output or logs, or if a
  checkout script executes after cloning or a failed repository update. Revoke a disclosed PAT
  through GitHub and correct the cause before retrying.

The launcher changes package prerequisites, protected credential storage,
root's GitHub credential-helper settings, and the chosen operations checkout. It does
not install a background bootstrap service. Retiring it requires an operator
to review those resources and any other workflows using the retained helper;
there is no automatic destructive uninstall.
