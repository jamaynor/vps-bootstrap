# VPS Bootstrap

One-command entry point for native Ubuntu service provisioning with
[jamaynor/vps-services](https://github.com/jamaynor/vps-services).

Run this **in your own SSH terminal**, on a running Ubuntu VPS with networking
and root or sudo access. No preinstalled Git or secrets are required:

```bash
curl -fsSL https://raw.githubusercontent.com/jamaynor/vps-bootstrap/main/bootstrap.sh | sudo bash
```

*(If `curl` is not preinstalled on a minimal image, install it first: `sudo apt-get update && sudo apt-get install -y curl`)*.

The launcher asks for your GitHub PAT with terminal echo disabled, stores it in
`/root/.secrets/gh_pat.txt`, fetches the private installer repository into
`/srv/repos/jamaynor/vps-services`, and opens its service-selection menu.

The PAT needs read access to the private repositories you intend to install,
including `jamaynor/vps-services`. Nothing in this public repository contains
credentials. Review `bootstrap.sh` before execution if desired; `main` is a
moving branch, so replace it with a reviewed commit ID for a fixed version.

## Shared prerequisites

To verify prerequisites or install only shared host prerequisites:

- **Prerequisites Status Checker & Launcher (`check-prereqs.sh`)**:
  Lists all prerequisite items with colored checkmarks (`[✓]` / `[✗]`) and prompts to install VPS services or quit:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/jamaynor/vps-bootstrap/main/check-prereqs.sh | bash
  ```

  Or locally: `./check-prereqs.sh` (or `./check-prereqs.sh --check` for status only).

- **Install Shared Prerequisites Only (`--prereqs`)**:
  Installs shared packages and developer agents without configuring GitHub credentials or checking out private repositories:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/jamaynor/vps-bootstrap/main/bootstrap.sh | sudo bash -s -- --prereqs
  ```

  Aliases `--shared-prereqs` and `--prerequisites` are also supported.

The shared prerequisites include:
- System packages: `git`, `ca-certificates`, `curl`, `gnupg`, `ufw`, `python3`, `python3-pip`, `python3-venv`, `python-is-python3`, `nodejs`, `npm`
- Web server: `caddy`
- Developer tooling: `gh` (GitHub CLI), `typescript` (`tsc`), `@anthropic-ai/claude-code`, `@openai/codex`, `@github/copilot`, and Antigravity CLI (`agy`)
- Non-root user PATH: Automatically configures `/usr/local/bin`, `/usr/bin`, `/etc/profile.d/vps-shared-path.sh`, and `~ubuntu/.local/bin` so all coding agents are available on `$PATH` for the `ubuntu` user and all login shells with `0755` permissions.

## Credential handling

- Enter the PAT only at the masked prompt in your own SSH terminal. Do not send
  it through agent chat, agent tools, command arguments, or environment variables.
- The secret directory is root-owned `0700`; the PAT is a regular, single-link,
  root-owned `0600` file. Unsafe existing paths are refused, not followed.
- Future runs reuse the file without displaying it. Cancelled or empty entry
  stops installation. If GitHub access fails, the installer does not proceed.
- A root-owned Git credential helper supplies the PAT only for HTTPS requests
  to `github.com` with a repository path under `jamaynor/`. The token is not
  embedded in clone URLs, Git configuration, or exported to application builds.
- Root's HTTPS GitHub credential helper configuration is replaced with this
  scoped helper after checkout succeeds. Other host credential entries remain.
- Root permissions do not isolate the file from a root-capable agent. Agents
  must never read it, invoke the helper to reveal it, or drive the secret prompt.
  An agent may supply this public command; you execute it separately in SSH.
- Do not use terminal recording or input-logging sudo configurations for secret
  entry. Masking prevents terminal echo; it cannot defeat privileged recording.

To replace a rejected or expired PAT, open your own SSH terminal and run:

```bash
sudo rm -- /root/.secrets/gh_pat.txt
```

Then rerun bootstrap to receive a fresh masked prompt. No existing credential
is printed. The credential file is plaintext protected by root-only access,
not encrypted storage.

## Reruns and scope

Existing checkouts must be root-owned, contain no symlinks or group/world-writable
paths, use the expected origin, be clean, and be on `main`. Updates are
fast-forward-only; failures stop before launch. Local edits are never reset,
stashed, or discarded. A partial clone is preserved for operator inspection.
Concurrent bootstrap runs are refused.

This launcher obtains access and opens the installer. The private repository
owns application provisioning and individual service prompts. The broader
requirement to collect every application-specific secret through a masked SSH
prompt is not implemented by this launcher. It does not run the older
`bootstrap-part1.sh` / `bootstrap-part2.sh` agent-toolchain workflow.

## Verification

```bash
bash -n bootstrap.sh
python3 -m unittest discover -s test -v
```

The credential tests require root in an isolated development/test environment;
they use temporary directories and synthetic PATs only. They check real PTY
masking, credential scope, retained-file permissions, unsafe paths, and refusal
of noninteractive execution. They never read `/root/.secrets` or provision the
host. Full fresh-Ubuntu installation still requires an operator-run smoke test.

See [fresh-host verification](docs/verification.md) for the operator smoke test
and failure/recovery signals.
