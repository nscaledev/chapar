"""Strict JSON loading shared across the CLI. Stdlib only."""

from __future__ import annotations

import json
from pathlib import Path
from typing import NoReturn

type JsonScalar = str | int | float | bool | None
type JsonValue = JsonScalar | list[JsonValue] | dict[str, JsonValue]
type JsonObject = dict[str, JsonValue]


class ChaparError(Exception):
    """A user-facing tool error; the CLI prints it and exits non-zero."""


def fail(message: str) -> NoReturn:
    raise ChaparError(message)


def unique_object(pairs: list[tuple[str, JsonValue]]) -> JsonObject:
    """Reject duplicate keys before json silently keeps the last one."""
    result: JsonObject = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> JsonObject:
    try:
        content = path.read_text(encoding="utf-8")
    except OSError as error:
        raise ChaparError(f"cannot read {path}: {error}") from error
    try:
        document = json.loads(content, object_pairs_hook=unique_object)
    except json.JSONDecodeError as error:
        raise ChaparError(f"malformed JSON: {path}: {error.msg}") from error
    if not isinstance(document, dict):
        raise ChaparError(f"{path} must contain a JSON object")
    return document


def mapping(value: JsonValue, label: str) -> JsonObject:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def string(value: JsonValue, label: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a non-empty string")
    return value


def strings(value: JsonValue, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        fail(f"{label} must be a non-empty string list")
    return tuple(item for item in value if isinstance(item, str))
