# Why this project was renamed to Pithos

Up to v0.2.8 this project was called **Tupperware**. From v0.3.0 it is
**Pithos**. The rename is not cosmetic — it was forced by two independent
blockers found while preparing the first release outside GitHub.

## 1. Trademark

"Tupperware" is a registered trademark of a long-established consumer goods
company. That is harmless for a private homelab tool that never leaves your
own machines. It is not harmless for software published under that name to a
public package index, where the name functions as a distribution identity.

The mark is also still actively owned: the brand passed to a new parent
following its previous owner's 2024 bankruptcy filing, and a mark in the hands
of new owners is if anything more likely to be enforced, not less.

Renaming before publication was cheaper than renaming after, and far cheaper
than a dispute.

## 2. The package name was already taken

`pip install tupperware` already resolves to an unrelated Python library. Even
setting the trademark aside, the name was unavailable on PyPI, so a rename was
required regardless.

## Why "Pithos"

A *pithos* is the large ceramic storage jar of ancient Greece — the vessel that
actually appears in the Pandora myth, which later mistranslation turned into a
"box". It keeps the original joke (this tool stores things in containers),
fits the naming convention used across the rest of this fleet, and is free of
the encumbrances above.

Note for search: an unrelated and well-known Linux Pandora Radio client is
also called Pithos, named for the same etymology. The two are easy to tell
apart in context; published artifacts from this project carry the `pithos-mcp`
name rather than a bare `pithos`.

## What changed

| Before | After |
|---|---|
| `/opt/tupperware` | `/opt/pithos` |
| `tupperware.service` | `pithos.service` |
| `tupperware-*` CLI commands | `pithos-*` |
| `/root/.tupperware/auth` | `/root/.pithos/auth` |
| `TUPPERWARE_*` env vars | `PITHOS_*` |
| `mcp/tupperware_mcp.py` | `mcp/pithos_mcp.py` |

## Compatibility

`TUPPERWARE_*` environment variables are still read as a fallback when the
matching `PITHOS_*` variable is unset, so a host installed before the rename
keeps working until its systemd drop-in is migrated. This fallback is
deprecated and will be removed in a future release — migrate your drop-ins.

## Don't forget the MCP client

The rename moves the MCP server's path *and* filename, so any MCP client
config still pointing at the old location will fail to start the server
entirely — the environment fallback does not help here, because the process
never launches.

In `claude_desktop_config.json` (and `~/.claude.json` for Claude Code):

```json
"pithos": {
  "command": "/path/to/pithos/mcp/.venv/bin/python",
  "args": ["/path/to/pithos/mcp/pithos_mcp.py"],
  "env": {
    "PITHOS_URL": "http://<host>:8080",
    "PITHOS_USER": "admin",
    "PITHOS_PASS": "<password>"
  }
}
```

Rename the server key from `tupperware` to `pithos`, update `command` and
`args` to the new paths, and rename the `TUPPERWARE_*` env keys. Restart the
client afterwards — these configs are read at launch.

If you renamed the checkout directory too, the existing virtualenv keeps
working; it does not need rebuilding.

Release notes for versions up to v0.2.8 are left under the old name on
purpose: they document what those versions actually shipped, and rewriting
them would make them false.
