"""Exercise all Perch tools with the official MCP SDK.

Run with a disposable PERCH_DATA path:
    uv run --with mcp python scripts/mcp_smoke.py <path-to-binary>
"""
import asyncio
import os
import re
import sys
from typing import Any

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

# Public names and parameter keys are the interop contract, not prose responses.
PARAMETERS = {
    "add_tasks": {"titles", "date", "literal"},
    "list_tasks": {"date"},
    "get_task": {"task", "date"},
    "complete_task": {"task"},
    "reopen_task": {"task"},
    "rename_task": {"task", "title", "date"},
    "delete_task": {"task", "date"},
    "move_task": {"task", "to", "from"},
    "update_task": {"task", "date", "title", "remind_at", "deadline", "priority", "project",
                    "notes", "repeat", "minutes", "steps", "done_steps"},
    "snooze_reminder": {"task", "minutes"},
    "start_timer": {"task", "minutes"},
    "pause_timer": set(),
    "resume_timer": set(),
    "stop_timer": set(),
    "read_notepad": {"date"},
    "write_notepad": {"text", "mode", "date"},
    "get_insights": set(),
    "list_projects": set(),
}


def field(model, snake, camel) -> Any:
    """MCP SDK releases have used both Python naming conventions."""
    return getattr(model, snake, getattr(model, camel, None))


async def main(binary):
    env = {"PERCH_DATA": os.environ["PERCH_DATA"], "TZ": os.environ.get("TZ", "America/Los_Angeles")}
    params = StdioServerParameters(command=binary, args=["--mcp"], env=env)
    async with stdio_client(params) as (reader, writer), ClientSession(reader, writer) as session:
        init = await session.initialize()
        server_info = field(init, "server_info", "serverInfo")
        assert server_info.name == "perch", server_info
        tools = (await session.list_tools()).tools
        assert len(tools) == len(PARAMETERS), len(tools)
        assert {tool.name for tool in tools} == set(PARAMETERS)
        for tool in tools:
            assert set(field(tool, "input_schema", "inputSchema")["properties"]) == PARAMETERS[tool.name], tool.name
            assert tool.description, tool.name
        seen = set()

        async def call(name, arguments=None, *, error=False, contains=None, equals=None):
            result = await session.call_tool(name, arguments or {})
            assert bool(field(result, "is_error", "isError")) == error, (name, result)
            text = "\n".join(item.text for item in result.content if item.type == "text")
            if contains is not None:
                assert contains in text, (name, text)
            if equals is not None:
                assert text == equals, (name, text)
            seen.add(name)
            return text

        title = "Review smoke output"
        renamed = "Verify smoke output"
        created = await call("add_tasks", {"titles": [title], "literal": True})
        identifier = re.search(r"\bid ([0-9a-f]{8})\b", created)
        assert identifier is not None, created
        task_id = identifier[1]
        await call("list_tasks", contains=title)
        await call("get_task", {"task": title}, contains=title)
        await call("rename_task", {"task": title, "title": renamed}, contains=renamed)
        await call("update_task", {"task": renamed, "priority": "high", "project": "Smoke",
                                   "steps": ["inspect output"], "done_steps": ["inspect output"]},
                   contains="[x] inspect output")
        await call("start_timer", {"task": renamed, "minutes": 5})
        await call("pause_timer", equals="Focus session paused.")
        await call("resume_timer", equals="Focus session resumed.")
        await call("stop_timer", equals="Focus ended; the task was not completed.")
        await call("stop_timer", error=True, equals="Start a focus session first.")
        await call("complete_task", {"task": renamed})
        await call("reopen_task", {"task": renamed})
        # Snoozing near the day boundary may reschedule the task. Use its id below.
        await call("snooze_reminder", {"task": task_id, "minutes": 5})
        await call("write_notepad", {"text": "Smoke note", "mode": "replace"})
        await call("read_notepad", contains="Smoke note")
        await call("get_insights")
        await call("list_projects", contains="#Smoke")
        await call("move_task", {"task": task_id, "to": "inbox"})
        await call("get_task", {"task": renamed, "date": "inbox"}, contains="Day: Inbox")
        await call("delete_task", {"task": renamed, "date": "inbox"})
        await call("add_tasks", {"titles": []}, error=True,
                   equals="Add at least one task title with text.")
        assert seen == set(PARAMETERS), set(PARAMETERS) - seen
        print(f"MCP smoke passed: {len(tools)} tool schemas, all {len(seen)} tools called, 2 expected errors.")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
