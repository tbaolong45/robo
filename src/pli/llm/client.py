"""Minimal client for any OpenAI-compatible chat endpoint (GLM, DeepSeek, ...).

Deliberately small: one POST, at most one retry, no async, no SDK. Callers gate
on `LLMClient.available` and treat every `LLMError` as "degrade to the
deterministic path" - an LLM outage must never break the planner.

`web_search` is the one thing here that is not a plain completion: it asks OpenRouter's web
plugin for the addresses of pages about a query, and uses nothing the model says.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from urllib.parse import urlsplit

import requests

from pli.config import Settings

TIMEOUT_SECONDS = 120
#: Room for one answer, the model's hidden thinking included. A 1000-word answer is about 1,500
#: tokens and thinking is usually a few hundred, but on some questions it runs on without end (a
#: chess endgame used 9,000 and 16,000 tokens, 45-70 s): this bounds the wait to about 25 s, after
#: which the call is repeated without thinking (see `complete_json`).
ANSWER_TOKENS = 6_000
#: A search answered in 1.8 s when measured (15 s on the default engine mode); a minute is
#: already a failed search, not a slow one.
SEARCH_TIMEOUT_SECONDS = 60
USER_AGENT = "pli/0.1 (personal study planner; +https://github.com/logrian)"

#: Leading ```json / ``` and trailing ``` that models wrap JSON in.
_FENCE = re.compile(r"^\s*```[a-zA-Z0-9_-]*\s*|\s*```\s*$")


class LLMError(RuntimeError):
    """Transport failure, non-2xx status, or output that is not valid JSON."""


class LLMFormatError(LLMError):
    """The model answered, but not with the JSON object that was asked for (text, or a list)."""


@dataclass(frozen=True)
class SearchHit:
    """One result of a web search: where it is, what it is called, and a short excerpt."""

    url: str
    title: str
    content: str


class LLMClient:
    """Stateless wrapper around `{base_url}/chat/completions`."""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    @property
    def available(self) -> bool:
        """False when no API key is configured - callers skip the LLM entirely."""
        return bool(self._settings.llm_api_key.strip())

    def complete_json(
        self, system: str, user: str, *, max_tokens: int = ANSWER_TOKENS, reasoning: bool = True
    ) -> dict:
        """Run one chat completion and return the parsed JSON object.

        The model thinks before it answers, which helps a little on hard problems (30 of 30 against
        29 of 30 on ten of them) and costs time on easy ones. `reasoning=False` skips it, for a job
        like rewriting a search query. And when a reply runs out of room while thinking - no answer,
        or half of one - the same request is made once more with thinking off: that answered the
        chess question that otherwise never came back in 4 s. Only OpenRouter takes the switch;
        another endpoint is sent nothing it might reject, and is not retried.

        Raises `LLMError` for anything that stops us returning a dict.
        """
        return _parse(self._complete(system, user, max_tokens, reasoning, as_json=True))

    def complete_text(
        self, system: str, user: str, *, max_tokens: int = ANSWER_TOKENS, reasoning: bool = True
    ) -> str:
        """The reply as plain text, asked for without JSON mode.

        For the one case JSON mode itself goes wrong: a free-text answer that has a quotation
        mark in it. The model starts a quoted phrase with a bare `"`, that closes the JSON string,
        and the provider's forced-JSON decoding fills in the rest, so `{"answer": "... means "}`
        comes back as a finished, valid reply (9 of 32 tries on one question, 0 of 32 without JSON
        mode). The same room and the same retry as `complete_json`. Raises `LLMError`.
        """
        return self._complete(system, user, max_tokens, reasoning, as_json=False).strip()

    def _complete(
        self, system: str, user: str, max_tokens: int, reasoning: bool, *, as_json: bool
    ) -> str:
        """What the model wrote, once any retry is done. Raises `LLMError`."""
        url = f"{self._settings.llm_base_url.rstrip('/')}/chat/completions"
        payload: dict = {
            "model": self._settings.llm_model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": 0.2,
            "max_tokens": max_tokens,
        }
        if as_json:
            payload["response_format"] = {"type": "json_object"}
        switch = {"enabled": False}  # OpenRouter's way to turn thinking off
        if not reasoning and self._is_openrouter():
            payload["reasoning"] = switch
        response = self._send(url, payload)
        if reasoning and self._is_openrouter() and _ran_out(response):
            payload["reasoning"] = switch
            response = self._send(url, payload)
        if not response.ok:
            raise LLMError(f"LLM returned HTTP {response.status_code}: {response.text[:500]}")
        if not as_json and _ran_out(
            response
        ):  # half an answer is not one; half a JSON is an error too
            raise LLMError("LLM ran out of room before it finished its answer")
        return _content_of(response.text)

    def _is_openrouter(self) -> bool:
        return urlsplit(self._settings.llm_base_url.rstrip("/")).hostname == "openrouter.ai"

    def _send(self, url: str, payload: dict) -> requests.Response:
        response = self._post(url, payload)
        # Some proxies reject response_format with a 400; retry ONCE without it.
        if response.status_code == 400 and "response_format" in response.text:
            payload.pop("response_format", None)
            response = self._post(url, payload)
        return response

    def web_search(self, query: str) -> list[SearchHit]:
        """The pages OpenRouter's web plugin finds for `query`, best first.

        Only the citations it attaches to the reply are used; whatever the model writes is
        thrown away, so a search result cannot steer anything through this call. Raises
        `LLMError` for any other endpoint (the plugin is OpenRouter's) and for any failure.
        """
        base = self._settings.llm_base_url.rstrip("/")
        if not self._is_openrouter():
            raise LLMError(
                "Web search needs LLM_BASE_URL to be OpenRouter (https://openrouter.ai/api/v1), "
                "which provides it. I can still open an address you give me."
            )
        payload = {
            "model": self._settings.llm_model,
            "messages": [
                {"role": "user", "content": f"Search the web for: {query}\nReply with the word OK."}
            ],
            "max_tokens": 8,
            "temperature": 0,
            "plugins": [{"id": "web", "engine": "exa", "mode": "instant", "max_results": 5}],
        }
        response = self._post(f"{base}/chat/completions", payload, SEARCH_TIMEOUT_SECONDS)
        if not response.ok:
            raise LLMError(
                f"Web search returned HTTP {response.status_code}: {response.text[:500]}"
            )
        return _hits(response.text)

    # --- internals ---------------------------------------------------------------

    def _post(self, url: str, payload: dict, timeout: float = TIMEOUT_SECONDS) -> requests.Response:
        try:
            return requests.post(
                url,
                json=payload,
                headers={
                    "Authorization": f"Bearer {self._settings.llm_api_key}",
                    "Content-Type": "application/json",
                    "User-Agent": USER_AGENT,
                },
                timeout=timeout,
            )
        except requests.RequestException as exc:  # timeout, DNS, TLS, connection reset...
            raise LLMError(f"LLM request failed: {exc}") from exc


def _ran_out(response: requests.Response) -> bool:
    """True when the reply stopped because it hit `max_tokens`, whatever it managed to write."""
    try:
        return json.loads(response.text)["choices"][0].get("finish_reason") == "length"
    except (json.JSONDecodeError, KeyError, IndexError, TypeError, AttributeError):
        return False


def _hits(raw: str) -> list[SearchHit]:
    """The `url_citation` annotations of a chat reply, skipping any that are not usable."""
    try:
        annotations = json.loads(raw)["choices"][0]["message"].get("annotations") or []
    except (json.JSONDecodeError, KeyError, IndexError, TypeError, AttributeError) as exc:
        raise LLMError(f"unexpected search envelope: {raw[:500]}") from exc
    hits: list[SearchHit] = []
    for note in annotations if isinstance(annotations, list) else []:
        cite = note.get("url_citation") if isinstance(note, dict) else None
        if not isinstance(note, dict) or note.get("type") != "url_citation":
            continue
        url = cite.get("url") if isinstance(cite, dict) else None
        if not isinstance(url, str) or not url:
            continue
        title, content = (cite.get(key) for key in ("title", "content"))
        hits.append(
            SearchHit(
                url,
                title if isinstance(title, str) else "",
                content if isinstance(content, str) else "",
            )
        )
    return hits


def _content_of(raw: str) -> str:
    """Pull `choices[0].message.content` out of the response envelope."""
    try:
        body = json.loads(raw)
        content = body["choices"][0]["message"]["content"]
    except (json.JSONDecodeError, KeyError, IndexError, TypeError) as exc:
        raise LLMError(f"unexpected LLM envelope: {raw[:500]}") from exc
    if isinstance(content, str):
        return content
    if isinstance(content, list):  # e.g. [{"type": "text", "text": "..."}]
        return "".join(part.get("text", "") for part in content if isinstance(part, dict))
    raise LLMError(f"unexpected message content: {str(content)[:500]}")


def _parse(content: str) -> dict:
    text = _FENCE.sub("", content.strip())
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        raise LLMFormatError(f"LLM did not return JSON: {content[:500]}") from exc
    if not isinstance(parsed, dict):
        raise LLMFormatError(
            f"LLM returned {type(parsed).__name__}, expected object: {content[:500]}"
        )
    return parsed
