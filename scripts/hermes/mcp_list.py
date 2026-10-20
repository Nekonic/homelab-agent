"""List MCP tools. usage:
  mcp_list.py stdio <cmd> [args...]            (env passed through)
  mcp_list.py sse|http <url> [BEARER_ENV_NAME]  (token read from env, never printed)
"""
import anyio, os, sys, json
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.client.sse import sse_client
from mcp.client.streamable_http import streamable_http_client, create_mcp_http_client

async def run(streams):
    r, w = streams[0], streams[1]
    async with ClientSession(r, w) as s:
        await s.initialize()
        tools = (await s.list_tools()).tools
        out = []
        for t in tools:
            a = t.annotations
            out.append({"name": t.name, "ro": getattr(a, "readOnlyHint", None) if a else None,
                        "destructive": getattr(a, "destructiveHint", None) if a else None})
        print(json.dumps(out))

async def main():
    kind = sys.argv[1]
    if kind == "stdio":
        p = StdioServerParameters(command=sys.argv[2], args=sys.argv[3:], env=dict(os.environ))
        async with stdio_client(p) as st: await run(st)
    else:
        url = sys.argv[2]; h = {}
        if len(sys.argv) > 3: h["Authorization"] = "Bearer " + os.environ[sys.argv[3]]
        if kind == "sse":
            async with sse_client(url, headers=h, timeout=15) as st: await run(st)
        else:
            async with create_mcp_http_client(headers=h) as c:
                async with streamable_http_client(url, http_client=c) as st: await run(st)
anyio.run(main)
