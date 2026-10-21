"""MCP-style tool schemas and o200k_base token counts."""

from __future__ import annotations

import json
from functools import lru_cache
from typing import Any

ENCODING_NAME = "o200k_base"


@lru_cache(maxsize=1)
def _enc():
    import tiktoken

    return tiktoken.get_encoding(ENCODING_NAME)


def count_tokens(text: str) -> int:
    return len(_enc().encode(text))


def input_schema(tool: dict[str, Any]) -> dict[str, Any]:
    props: dict[str, Any] = {}
    required: list[str] = []
    for p in tool.get("params") or []:
        props[p] = {
            "type": "string",
            "description": f"{p.replace('_', ' ')} for {tool['name']}",
        }
        if p in ("id", "query", "path", "owner", "repo", "title", "name", "sql", "soql"):
            required.append(p)
    schema: dict[str, Any] = {"type": "object", "properties": props}
    if required:
        schema["required"] = required
    return schema


def tool_schema(tool: dict[str, Any]) -> dict[str, Any]:
    """One tool as an MCP tools/list / search_tools hit."""
    return {
        "name": tool["id"],
        "description": tool["description"],
        "inputSchema": input_schema(tool),
        "_meta": {"server": tool["server"]},
    }


def search_payload(tools: list[dict[str, Any]], query: str, offset: int = 0) -> str:
    """Compact JSON a search_tools MCP call would return to the model."""
    body = {
        "query": query,
        "offset": offset,
        "count": len(tools),
        "tools": [tool_schema(t) for t in tools],
    }
    return json.dumps(body, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def all_schemas_payload(tools: list[dict[str, Any]]) -> str:
    body = {"tools": [tool_schema(t) for t in tools]}
    return json.dumps(body, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
