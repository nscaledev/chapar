"""Shared urllib JSON transport for the CVE checker. Stdlib only."""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass

from chapar.common.jsonio import JsonObject


@dataclass(frozen=True, slots=True)
class HttpRequestError(RuntimeError):
    message: str

    def __str__(self) -> str:
        return self.message


def urlopen_json(request: urllib.request.Request, timeout: int = 60) -> JsonObject:
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise HttpRequestError(
            f"HTTP {error.code} from {request.full_url}: {body[:500]}"
        ) from error
    except urllib.error.URLError as error:
        raise HttpRequestError(f"failed to fetch {request.full_url}: {error}") from error
    except TimeoutError as error:
        raise HttpRequestError(f"timed out fetching {request.full_url}: {error}") from error
    data = json.loads(payload)
    if not isinstance(data, dict):
        raise HttpRequestError(f"expected JSON object from {request.full_url}")
    return data
