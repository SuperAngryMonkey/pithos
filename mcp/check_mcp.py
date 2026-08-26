#!/usr/bin/env python3
"""Standalone MCP handshake check — proves pithos_mcp.py works as an MCP
server without involving Claude Code. Run from the mcp/ dir:

    ./.venv/bin/python check_mcp.py

Success prints the server name and the three tool names. If this works but
Claude Code shows the server as failed, the problem is the `claude mcp add`
registration line, not the server.
"""
import asyncio
import os
import sys
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main():
    # The MCP SDK gives spawned servers a minimal environment, so PITHOS_*
    # must be forwarded explicitly or the server exits before the handshake.
    env = {k: v for k, v in os.environ.items()
           if k.startswith(("PITHOS_", "TUPPERWARE_")) or k in ("PATH", "HOME")}
    if not (env.get("PITHOS_URL") or env.get("TUPPERWARE_URL")):
        print("PITHOS_URL is not set - export it before running this check.",
              file=sys.stderr)
        raise SystemExit(2)
    params = StdioServerParameters(command="./.venv/bin/python",
                                   args=["pithos_mcp.py"], env=env)
    async with stdio_client(params) as (r, w):
        async with ClientSession(r, w) as s:
            info = await s.initialize()
            tools = await s.list_tools()
            print("server:", info.serverInfo.name)
            print("tools :", [t.name for t in tools.tools])
            print("HANDSHAKE OK")


if __name__ == "__main__":
    asyncio.run(main())
