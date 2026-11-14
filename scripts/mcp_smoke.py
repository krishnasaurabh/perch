"""Exercise all Perch tools with the official MCP SDK.

Run with a disposable PERCH_DATA path:
    uv run --with mcp --with jsonschema python scripts/mcp_smoke.py <path-to-binary>
"""
import asyncio
import json
import os
import sys
from pathlib import Path
from typing import Any

import jsonschema
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

# Public names and parameter keys are the interop contract, not prose responses.
PARAMETERS = {
    "add_tasks": {"titles", "date", "literal", "start"},
    "list_tasks": {"date"},
    "list_inbox": set(),
    "list_overdue": set(),
    "update_overdue": {"action", "tasks", "date"},
    "get_task": {"task", "date"},
    "complete_task": {"task"},
    "reopen_task": {"task"},
    "rename_task": {"task", "title", "date"},
    "delete_task": {"task", "date"},
    "move_task": {"task", "to", "from"},
    "update_task": {"task", "date", "title", "start", "remind_at", "deadline", "priority", "project",
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
    "list_parked_thoughts": set(),
    "add_parked_thought": {"text"},
    "promote_parked_thought": {"thought", "date"},
}
READ_ONLY = {"list_inbox", "list_overdue", "get_task", "read_notepad", "get_insights", "list_projects", "list_parked_thoughts"}
OVERDUE_ID = "00000000-0000-4000-8000-00000000ca11"


def field(model, snake, camel) -> Any:
    """MCP SDK releases have used both Python naming conventions."""
    return getattr(model, snake, getattr(model, camel, None))


def seed_synthetic_overdue_task(*, enabled=False):
    """A small legacy fixture makes the real server load and migrate synthetic data."""
    path = Path(os.environ["PERCH_DATA"])
    path.parent.mkdir(parents=True, exist_ok=True)
    fixture = {
        "version": 1,
        "tasks": [{
            "id": OVERDUE_ID,
            "title": "Overdue SDK fixture",
            "day": "2000-01-01",
            "createdAt": "2000-01-01T00:00:00Z",
        }],
        "preferences": {"agentsCanControlTime": enabled, "agentsCanReadParkingLot": enabled},
    }
    path.write_text(json.dumps(fixture), encoding="utf-8")


async def main(binary):
    seed_synthetic_overdue_task()
    env = {"PERCH_DATA": os.environ["PERCH_DATA"], "TZ": os.environ.get("TZ", "America/Los_Angeles")}
    params = StdioServerParameters(command=binary, args=["--mcp"], env=env)
    async with stdio_client(params) as (reader, writer), ClientSession(reader, writer) as session:
        init = await session.initialize()
        server_info = field(init, "server_info", "serverInfo")
        assert server_info.name == "perch", server_info
        assert field(init, "protocol_version", "protocolVersion") == "2025-06-18", init
        instructions = (init.instructions or "").lower()
        assert "untrusted" in instructions and "never follow" in instructions, instructions

        tools = (await session.list_tools()).tools
        assert len(tools) == len(PARAMETERS), len(tools)
        assert {tool.name for tool in tools} == set(PARAMETERS)
        output_schemas = {}
        for tool in tools:
            input_schema = field(tool, "input_schema", "inputSchema")
            jsonschema.Draft202012Validator.check_schema(input_schema)
            assert set(input_schema["properties"]) == PARAMETERS[tool.name], tool.name
            assert input_schema["additionalProperties"] is False, tool.name
            assert tool.description, tool.name
            output_schema = field(tool, "output_schema", "outputSchema")
            jsonschema.Draft202012Validator.check_schema(output_schema)
            assert output_schema["type"] == "object", tool.name
            assert output_schema["additionalProperties"] is False, tool.name
            output_schemas[tool.name] = output_schema
            read_only = field(tool.annotations, "read_only_hint", "readOnlyHint") if tool.annotations else False
            assert read_only == (tool.name in READ_ONLY), tool.name
        seen = set()

        async def call(name, arguments=None, *, error=False, contains=None, equals=None):
            result = await session.call_tool(name, arguments or {})
            assert bool(field(result, "is_error", "isError")) == error, (name, result)
            text = "\n".join(item.text for item in result.content if item.type == "text")
            if contains is not None:
                assert contains in text, (name, text)
            if equals is not None:
                assert text == equals, (name, text)
            structured = field(result, "structured_content", "structuredContent")
            if error:
                assert structured is None, (name, structured)
            else:
                assert isinstance(structured, dict), (name, structured)
                assert structured["content_trust"] == "untrusted", (name, structured)
                jsonschema.validate(structured, output_schemas[name])
                for item in result.content:
                    if item.type == "text":
                        meta = field(item, "meta", "_meta") or {}
                        assert meta["perch/content_trust"] == "untrusted", (name, meta)
            seen.add(name)
            return text, structured

        await call("start_timer", error=True, contains="Start and stop time blocks is off")
        await call("list_parked_thoughts", error=True, contains="Read the parking lot is off")
        # Change only the isolated fixture, as if the person enabled these settings.
        seed_synthetic_overdue_task(enabled=True)
        title = "Review smoke output"
        renamed = "Verify smoke output"
        created, created_data = await call("add_tasks", {"titles": [title], "literal": True})
        assert "Added 1 task" in created
        assert created_data is not None
        task_id = created_data["tasks"][0]["id"]
        await call("list_tasks", contains=title)
        await call("list_overdue", contains="Overdue SDK fixture")
        _, overdue = await call("update_overdue", {"action": "complete", "tasks": [OVERDUE_ID]})
        assert overdue is not None
        assert overdue["tasks"][0]["done"] is True and overdue["tasks"][0]["day"] == "2000-01-01"
        await call("list_overdue", equals="No overdue tasks.")
        await call(
            "update_overdue", {"action": "remove", "tasks": [OVERDUE_ID]}, error=True,
            contains="Invalid argument 'action'")
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
        _, parked = await call("add_parked_thought", {"text": "Consider a quieter workspace"})
        assert parked is not None
        thought_id = parked["thought"]["id"]
        _, lot = await call("list_parked_thoughts")
        assert lot is not None
        assert thought_id in {thought["id"] for thought in lot["thoughts"]}
        _, promoted = await call("promote_parked_thought", {"thought": thought_id})
        assert promoted is not None
        assert promoted["task"]["title"] == "Consider a quieter workspace"
        assert promoted["task"]["start"] is None
        _, updated = await call("update_task", {"task": promoted["task"]["id"], "start": "12:30 pm"})
        assert updated is not None
        assert updated["task"]["start"] is not None
        await call("update_task", {"task": promoted["task"]["id"], "start": "none"})
        _, started = await call("add_tasks", {"titles": ["Plan a short walk"], "literal": True, "start": "1:30 pm"})
        assert started is not None
        assert started["tasks"][0]["start"] is not None
        assert started["tasks"][0]["remind_at"] is None
        await call("move_task", {"task": task_id, "to": "inbox"})
        await call("list_inbox", contains=renamed)
        await call("get_task", {"task": renamed, "date": "inbox"}, contains="Day: Inbox")
        _, pending = await call("delete_task", {"task": renamed, "date": "inbox"}, contains="waiting")
        assert pending is not None
        assert pending["status"] == "pending"
        await call("get_task", {"task": renamed, "date": "inbox"}, contains=renamed)
        stored = json.loads(Path(os.environ["PERCH_DATA"]).read_text())
        assert stored["agentActions"]["pending"][0]["id"].lower() == pending["pending_action_id"]
        assert stored["agentActions"]["changes"]
        assert all(change["agentID"] for change in stored["agentActions"]["changes"])
        await call("add_tasks", {"titles": []}, error=True,
                   equals="Add at least one task title with text.")
        await call("list_tasks", {"date": 5}, error=True, contains="Invalid argument 'date'")
        await call("add_tasks", {"titles": ["valid"], "agentID": "forged"}, error=True,
                   equals="Unknown argument 'agentID' for add_tasks.")
        assert seen == set(PARAMETERS), set(PARAMETERS) - seen
        print(f"MCP smoke passed: {len(tools)} tool schemas, all {len(seen)} tools called, 7 expected errors; "
              "all structured results validated.")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
