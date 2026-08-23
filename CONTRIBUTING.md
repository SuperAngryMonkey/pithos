# Contributing to Pithos

Issues and PRs welcome.

## What's likely to land

- **Bug fixes** for genuine breakage
- **Compatibility improvements** for newer Proxmox or Tailscale versions
- **New optional features** (multi-tag support, bulk creation, full clones, etc.) that don't bloat the default path
- **Documentation improvements** — especially troubleshooting scenarios

## What's likely NOT to land

- **Heavy frameworks** — keep the Flask app a single file, no JS bundlers
- **Complex auth on the web UI** — out of scope for default install. See architecture docs for how to add it externally.
- **Multi-host support** — Pithos is single-host by design. If you want a multi-host orchestrator, that's a different project.

## Development

You need a Proxmox VE host to test. There's no realistic way to test without one. Spinning up a nested Proxmox VM works for integration testing.

Suggested workflow:
1. Fork the repo
2. Clone your fork to your dev Proxmox host
3. `./scripts/install.sh` to install in place
4. `./scripts/install-webui.sh` for the UI
5. Make changes
6. Re-run the install scripts (they're idempotent)
7. Test from your browser

## Code style

- **Bash**: pass shellcheck. Use `set -euo pipefail` everywhere.
- **Python**: PEP 8 reasonable. The Flask app is intentionally small — don't refactor into multiple files unless there's a real need.
- **HTML/CSS**: stays inline in the Python template. Single-file deploy is a feature.

## Issue templates

When reporting bugs, please include:

- Proxmox VE version (`pveversion`)
- Tailscale version on host AND container (`tailscale version`)
- Output of the failing command
- Output of `journalctl -u pithos -n 50`
- Output of `pct exec <vmid> -- cat /var/log/tailscale-firstboot.log` (if relevant)

## License

MIT. By contributing, you agree your contributions are MIT-licensed.
