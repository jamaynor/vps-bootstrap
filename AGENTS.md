# VPS Bootstrap Agent Policy

This public repository contains only the launcher, its documentation, and tests.
Application provisioning belongs to jamaynor/vps-services.

Never read /root/.secrets/gh_pat.txt, call the installed credential helper to
inspect its output, or request a PAT through agent tools. Never run bootstrap
main on the operator's live host as a test. Use synthetic tokens in isolated
fixtures. Never put credentials in commands, URLs, environments, logs, or commits.

Run bash syntax validation and the Python unittest suite before publishing.
Keep the public launcher compatible with bare Ubuntu and root/sudo SSH use.
