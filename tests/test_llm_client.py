"""The OpenAI-compatible HTTP client - the one module that holds the API key.

Every other test in the suite installs a *stub* in this module's place (see
`tests/test_score.py`), which is the right thing for testing the scorer and the
wrong thing for testing the client: it left the request building, the envelope
parsing and the credential handling with no coverage at all. This file tests the
real class against a fake `requests.post`.

Two rules are load-bearing here and neither is visible from a passing run:

* **Nothing degrades into an empty answer.** Callers read `LLMError` as "skip the
  LLM and use the deterministic path"; a client that returned `{}` on a 500 would
  instead hand back a plan with every score silently defaulted, which looks like a
  successful run.
* **The key never reaches a message.** `Authorization: Bearer <key>` is built per
  request, and an error string carrying it would end up in a log file.
"""

from __future__ import annotations

import json

import pytest
import requests

from pli.config import Settings
from pli.llm.client import (
    ANSWER_TOKENS,
    SEARCH_TIMEOUT_SECONDS,
    TIMEOUT_SECONDS,
    LLMClient,
    LLMError,
    LLMFormatError,
    _content_of,
    _parse,
)

KEY = "ts-secret-do-not-log-me"


def _settings(**kwargs: object) -> Settings:
    kwargs.setdefault("llm_api_key", KEY)
    kwargs.setdefault("llm_base_url", "https://api.deepseek.com")
    return Settings(_env_file=None, **kwargs)


class _Response:
    """Enough of `requests.Response` for `complete_json`."""

    def __init__(self, *, status_code: int = 200, body: str = "{}") -> None:
        self.status_code = status_code
        self.text = body

    @property
    def ok(self) -> bool:
        return 200 <= self.status_code < 300


def _envelope(content: str) -> str:
    return f'{{"choices": [{{"message": {{"content": {_json_string(content)}}}}}]}}'


def _json_string(text: str) -> str:
    return json.dumps(text)


def _install(monkeypatch, *responses: _Response) -> list[dict]:
    """Replace `requests.post`; return the list of payloads it was called with."""
    sent: list[dict] = []

    def fake_post(url, *, json=None, headers=None, timeout=None):
        # Copy the payload: `complete_json` mutates the dict in place on the
        # response_format retry, so holding the reference would rewrite the record
        # of the first request.
        sent.append({"url": url, "payload": dict(json or {}), "headers": headers or {}})
        index = min(len(sent) - 1, len(responses) - 1)
        return responses[index]

    monkeypatch.setattr("pli.llm.client.requests.post", fake_post)
    return sent


# --- availability ---------------------------------------------------------------


def test_no_key_means_not_available():
    """`score_tasks` gates on this; a True here would send an unauthenticated
    request on every plan."""
    assert not LLMClient(_settings(llm_api_key="")).available


def test_a_whitespace_key_is_not_a_key():
    assert not LLMClient(_settings(llm_api_key="   \n")).available


def test_a_configured_key_is_available():
    assert LLMClient(_settings()).available


# --- the happy path -------------------------------------------------------------


def test_a_json_object_comes_back(monkeypatch):
    sent = _install(monkeypatch, _Response(body=_envelope('{"a": 1}')))

    assert LLMClient(_settings()).complete_json("sys", "user") == {"a": 1}
    assert sent[0]["url"] == "https://api.deepseek.com/chat/completions"


def test_a_trailing_slash_on_the_base_url_does_not_double_up(monkeypatch):
    sent = _install(monkeypatch, _Response(body=_envelope("{}")))

    LLMClient(_settings(llm_base_url="https://api.deepseek.com/")).complete_json("s", "u")

    assert sent[0]["url"] == "https://api.deepseek.com/chat/completions"


def test_the_model_and_messages_are_sent(monkeypatch):
    sent = _install(monkeypatch, _Response(body=_envelope("{}")))

    LLMClient(_settings(llm_model="glm-4")).complete_json("be terse", "score these")

    payload = sent[0]["payload"]
    assert payload["model"] == "glm-4"
    assert payload["messages"] == [
        {"role": "system", "content": "be terse"},
        {"role": "user", "content": "score these"},
    ]


# --- the credential -------------------------------------------------------------


def test_the_key_is_sent_as_a_bearer_token(monkeypatch):
    sent = _install(monkeypatch, _Response(body=_envelope("{}")))

    LLMClient(_settings()).complete_json("s", "u")

    assert sent[0]["headers"]["Authorization"] == f"Bearer {KEY}"


def test_the_key_never_appears_in_a_failure_message(monkeypatch):
    """These strings reach the console and the logs. The header is built per
    request, so the key is in scope at every raise site - it must not be
    interpolated into one."""
    _install(monkeypatch, _Response(status_code=500, body="upstream exploded"))

    with pytest.raises(LLMError) as raised:
        LLMClient(_settings()).complete_json("s", "u")

    assert KEY not in str(raised.value)


def test_a_transport_error_does_not_leak_the_key(monkeypatch):
    """A `requests` failure text is passed through to the message, and that text
    must not be made to carry the credential. The client builds the header itself,
    so the key is in scope at the raise site - it must not be interpolated in."""
    reached = {}

    def explode(url, *, json=None, headers=None, timeout=None):
        reached["headers"] = headers or {}
        # What urllib3 actually says: the host, the URL, the cause. No headers.
        raise requests.ConnectionError(
            "HTTPSConnectionPool(host='api.deepseek.com', port=443): Max retries "
            "exceeded with url: /chat/completions (Caused by ConnectTimeoutError())"
        )

    monkeypatch.setattr("pli.llm.client.requests.post", explode)

    with pytest.raises(LLMError) as raised:
        LLMClient(_settings()).complete_json("s", "u")

    assert reached["headers"]["Authorization"] == f"Bearer {KEY}", "the key was never sent"
    assert KEY not in str(raised.value)


# --- failures are failures, never empty answers -----------------------------------


def test_a_server_error_is_an_error_and_not_an_empty_dict(monkeypatch):
    """`{}` here would read as "the model answered nothing", and the caller would
    keep going with defaulted scores."""
    _install(monkeypatch, _Response(status_code=500, body="boom"))

    with pytest.raises(LLMError, match="500"):
        LLMClient(_settings()).complete_json("s", "u")


def test_a_transport_exception_becomes_an_llm_error(monkeypatch):
    def explode(url, **kwargs):
        raise requests.Timeout("read timed out")

    monkeypatch.setattr("pli.llm.client.requests.post", explode)

    with pytest.raises(LLMError):
        LLMClient(_settings()).complete_json("s", "u")


def test_a_non_json_body_is_an_error(monkeypatch):
    _install(monkeypatch, _Response(body="<html>gateway</html>"))

    with pytest.raises(LLMError, match="envelope"):
        LLMClient(_settings()).complete_json("s", "u")


def test_content_that_is_not_json_is_an_error(monkeypatch):
    _install(monkeypatch, _Response(body=_envelope("I cannot help with that")))

    with pytest.raises(LLMError, match="did not return JSON"):
        LLMClient(_settings()).complete_json("s", "u")


# --- the response_format retry ----------------------------------------------------


def test_a_400_over_response_format_retries_once_without_it(monkeypatch):
    """Some proxies reject the field; the retry is the difference between working
    and failing outright on those hosts."""
    sent = _install(
        monkeypatch,
        _Response(status_code=400, body='{"error": "unknown field response_format"}'),
        _Response(body=_envelope('{"ok": true}')),
    )

    assert LLMClient(_settings()).complete_json("s", "u") == {"ok": True}
    assert len(sent) == 2
    assert "response_format" in sent[0]["payload"]
    assert "response_format" not in sent[1]["payload"]


def test_a_400_for_another_reason_is_not_retried(monkeypatch):
    """Retrying a genuine bad request doubles the cost and hides the real error."""
    sent = _install(monkeypatch, _Response(status_code=400, body='{"error": "bad model"}'))

    with pytest.raises(LLMError, match="400"):
        LLMClient(_settings()).complete_json("s", "u")

    assert len(sent) == 1


# --- the parsing helpers -----------------------------------------------------------


def test_a_json_fence_is_stripped():
    assert _parse('```json\n{"a": 1}\n```') == {"a": 1}


def test_a_bare_fence_is_stripped():
    assert _parse('```\n{"a": 1}\n```') == {"a": 1}


def test_json_that_is_not_an_object_is_an_error():
    with pytest.raises(LLMError, match="expected object"):
        _parse("[1, 2, 3]")


def test_content_as_a_list_of_parts_is_joined():
    """Some endpoints return content as [{"type": "text", "text": "..."}]."""
    raw = '{"choices": [{"message": {"content": [{"type": "text", "text": "{}"}]}}]}'

    assert _content_of(raw) == "{}"


def test_a_missing_choice_is_an_error():
    with pytest.raises(LLMError, match="envelope"):
        _content_of('{"choices": []}')


# --- web search (OpenRouter's web plugin) ----------------------------------------------------

OPENROUTER = "https://openrouter.ai/api/v1"


def _annotated(*citations: object) -> _Response:
    """A chat reply whose message carries `annotations`, as OpenRouter's web plugin returns them."""
    message = {"role": "assistant", "content": "OK", "annotations": list(citations)}
    return _Response(body=json.dumps({"choices": [{"message": message}]}))


def _cite(url: object, title: object = "T", content: object = "C") -> dict:
    return {
        "type": "url_citation",
        "url_citation": {"url": url, "title": title, "content": content},
    }


def test_a_web_search_asks_openrouters_plugin_for_a_few_fast_results(monkeypatch):
    """Only the citations are used, so the request is as small as it can be: the Exa engine in
    `instant` mode answered in 1.8 s against 15 s for the default, and cost the same."""
    sent = _install(monkeypatch, _annotated(_cite("https://a.example/")))
    client = LLMClient(_settings(llm_base_url=OPENROUTER, llm_model="deepseek/some-model"))

    client.web_search("python 3.15 release")

    [call] = sent
    assert call["url"] == f"{OPENROUTER}/chat/completions"
    assert call["headers"]["Authorization"] == f"Bearer {KEY}"
    payload = call["payload"]
    assert payload["model"] == "deepseek/some-model"
    assert payload["plugins"] == [
        {"id": "web", "engine": "exa", "mode": "instant", "max_results": 5}
    ]
    assert "python 3.15 release" in payload["messages"][-1]["content"]
    assert payload["max_tokens"] <= 16
    assert "response_format" not in payload


def test_the_citations_come_back_in_order_with_their_title_and_text(monkeypatch):
    _install(
        monkeypatch,
        _annotated(
            _cite("https://a.example/1", "First", "alpha"),
            _cite("https://b.example/2", "Second", ""),
        ),
    )

    hits = LLMClient(_settings(llm_base_url=OPENROUTER)).web_search("q")

    assert [(h.url, h.title, h.content) for h in hits] == [
        ("https://a.example/1", "First", "alpha"),
        ("https://b.example/2", "Second", ""),
    ]


def test_citations_that_are_not_usable_are_skipped_not_fatal(monkeypatch):
    _install(
        monkeypatch,
        _annotated(
            {"type": "file_citation", "url_citation": {"url": "https://x.example/"}},
            {"type": "url_citation"},
            {"type": "url_citation", "url_citation": "nope"},
            {"type": "url_citation", "url_citation": {"url": 42}},
            {"type": "url_citation", "url_citation": {"url": ""}},
            "not even a dict",
            _cite("https://ok.example/", title=None, content=None),
        ),
    )

    hits = LLMClient(_settings(llm_base_url=OPENROUTER)).web_search("q")

    assert [(h.url, h.title, h.content) for h in hits] == [("https://ok.example/", "", "")]


def test_a_reply_with_no_citations_is_an_empty_search_not_an_error(monkeypatch):
    _install(monkeypatch, _Response(body=_envelope("OK")))

    assert LLMClient(_settings(llm_base_url=OPENROUTER)).web_search("q") == []


def test_the_models_own_words_are_never_part_of_the_result(monkeypatch):
    _install(monkeypatch, _annotated(_cite("https://a.example/")))

    hits = LLMClient(_settings(llm_base_url=OPENROUTER)).web_search("q")

    assert not any("OK" in (h.url + h.title + h.content) for h in hits)


@pytest.mark.parametrize(
    "base",
    [
        "https://api.deepseek.com",
        "https://openrouter.ai.evil.example/api/v1",
        "https://evil.example/openrouter.ai",
        "http://localhost:8000/v1",
    ],
)
def test_web_search_is_only_asked_of_openrouter_and_sends_nothing_elsewhere(monkeypatch, base):
    sent = _install(monkeypatch, _annotated(_cite("https://a.example/")))

    with pytest.raises(LLMError, match="OpenRouter"):
        LLMClient(_settings(llm_base_url=base)).web_search("q")

    assert sent == []


def test_a_failed_search_is_an_error_and_never_carries_the_key(monkeypatch):
    _install(monkeypatch, _Response(status_code=402, body="out of credits"))

    with pytest.raises(LLMError, match="402") as raised:
        LLMClient(_settings(llm_base_url=OPENROUTER)).web_search("q")

    assert KEY not in str(raised.value)


def test_a_search_that_cannot_reach_the_service_is_an_error(monkeypatch):
    def boom(*args, **kwargs):
        raise requests.ConnectionError("no route")

    monkeypatch.setattr("pli.llm.client.requests.post", boom)

    with pytest.raises(LLMError, match="no route"):
        LLMClient(_settings(llm_base_url=OPENROUTER)).web_search("q")


def test_a_reply_that_is_not_the_expected_envelope_is_an_error(monkeypatch):
    _install(monkeypatch, _Response(body='{"unexpected": true}'))

    with pytest.raises(LLMError):
        LLMClient(_settings(llm_base_url=OPENROUTER)).web_search("q")


def test_a_search_waits_less_than_a_completion(monkeypatch):
    seen: list[float] = []

    def fake_post(url, *, json=None, headers=None, timeout=None):
        seen.append(timeout)
        return _annotated(_cite("https://a.example/"))

    monkeypatch.setattr("pli.llm.client.requests.post", fake_post)

    LLMClient(_settings(llm_base_url=OPENROUTER)).web_search("q")

    assert seen == [SEARCH_TIMEOUT_SECONDS] and SEARCH_TIMEOUT_SECONDS < TIMEOUT_SECONDS


# --- a model that thinks without end ------------------------------------------------------------
# Measured with the deployed model: some questions (a chess endgame) make its hidden reasoning run
# to whatever limit it is given - 9,000 and 16,000 tokens were both used up, 45-70 s, and no
# answer came back (content None or cut off, finish_reason "length"). Asking for a smaller
# reasoning effort or budget did nothing; only switching reasoning off stopped it, and then the
# same question took 4 s. Across 80 maths and logic problems with known answers reasoning on and
# off scored 77/80 and 77/80 (30/30 against 29/30 on the ten hardest), so it is kept on and the
# call is repeated with it off only when the first ran out of room.


def _reply(content, finish="stop") -> _Response:
    body = {"choices": [{"message": {"content": content}, "finish_reason": finish}]}
    return _Response(body=json.dumps(body))


def _ran_out(content=None) -> _Response:
    return _reply(content, "length")


def _thinking(payload: dict) -> object:
    return payload.get("reasoning")


def test_the_default_room_for_an_answer_is_enough_for_a_long_one_and_for_some_thinking():
    assert ANSWER_TOKENS >= 6_000  # a 1000-word answer is ~1,500 tokens; thinking has its share


def test_an_ordinary_answer_is_one_request_and_leaves_reasoning_alone(monkeypatch):
    sent = _install(monkeypatch, _reply('{"answer": "42"}'))

    result = LLMClient(_settings(llm_base_url=OPENROUTER)).complete_json("sys", "user")

    assert result == {"answer": "42"} and len(sent) == 1
    assert "reasoning" not in sent[0]["payload"]
    assert sent[0]["payload"]["max_tokens"] == ANSWER_TOKENS


def test_a_reply_cut_off_while_thinking_is_asked_again_with_reasoning_off(monkeypatch):
    sent = _install(monkeypatch, _ran_out(None), _reply('{"answer": "Lucena"}'))

    result = LLMClient(_settings(llm_base_url=OPENROUTER)).complete_json("sys", "user")

    assert result == {"answer": "Lucena"} and len(sent) == 2
    assert "reasoning" not in sent[0]["payload"]
    assert _thinking(sent[1]["payload"]) == {"enabled": False}
    assert sent[1]["payload"]["messages"] == sent[0]["payload"]["messages"]  # the same question


def test_a_half_written_answer_counts_as_cut_off_too(monkeypatch):
    sent = _install(
        monkeypatch,
        _ran_out('{"answer": "The Lucena position is the cla'),
        _reply('{"answer": "ok"}'),
    )

    assert LLMClient(_settings(llm_base_url=OPENROUTER)).complete_json("s", "u") == {"answer": "ok"}
    assert len(sent) == 2


def test_the_second_try_is_the_last_if_that_runs_out_too(monkeypatch):
    sent = _install(monkeypatch, _ran_out(None), _ran_out('{"answer": "cut'))

    with pytest.raises(LLMError):
        LLMClient(_settings(llm_base_url=OPENROUTER)).complete_json("s", "u")

    assert len(sent) == 2


def test_a_call_that_already_does_without_reasoning_is_not_repeated(monkeypatch):
    sent = _install(monkeypatch, _ran_out(None))

    with pytest.raises(LLMError):
        LLMClient(_settings(llm_base_url=OPENROUTER)).complete_json("s", "u", reasoning=False)

    assert len(sent) == 1 and _thinking(sent[0]["payload"]) == {"enabled": False}


def test_a_small_job_can_ask_to_skip_reasoning_from_the_start(monkeypatch):
    sent = _install(monkeypatch, _reply('{"query": "weather"}'))

    LLMClient(_settings(llm_base_url=OPENROUTER)).complete_json("s", "u", reasoning=False)

    assert _thinking(sent[0]["payload"]) == {"enabled": False}


def test_another_endpoint_is_never_sent_a_field_it_may_reject(monkeypatch):
    """`reasoning` is OpenRouter's; a plain OpenAI-style endpoint could answer 400 to it."""
    sent = _install(monkeypatch, _reply('{"answer": "x"}'), _ran_out(None))
    client = LLMClient(_settings(llm_base_url="https://api.deepseek.com"))

    client.complete_json("s", "u", reasoning=False)  # never sends it
    with pytest.raises(LLMError):
        client.complete_json("s", "u")  # and a cut-off reply is not "fixed" by sending it

    assert all("reasoning" not in call["payload"] for call in sent)
    assert len(sent) == 2  # one request each: no retry that could not help


def test_the_retry_keeps_the_response_format_workaround(monkeypatch):
    sent = _install(
        monkeypatch,
        _Response(status_code=400, body="response_format is not supported"),
        _ran_out(None),
        _reply('{"answer": "ok"}'),
    )

    result = LLMClient(_settings(llm_base_url=OPENROUTER)).complete_json("s", "u")

    assert result == {"answer": "ok"} and len(sent) == 3
    assert "response_format" not in sent[2]["payload"] and _thinking(sent[2]["payload"]) == {
        "enabled": False
    }


def test_a_later_call_starts_with_reasoning_on_again(monkeypatch):
    sent = _install(
        monkeypatch, _ran_out(None), _reply('{"answer": "a"}'), _reply('{"answer": "b"}')
    )
    client = LLMClient(_settings(llm_base_url=OPENROUTER))

    client.complete_json("s", "u")
    client.complete_json("s", "u")

    assert "reasoning" not in sent[2]["payload"]


@pytest.mark.parametrize(
    "body",
    [
        "not json at all",
        "[]",
        '{"choices": []}',
        '{"choices": [null]}',
        '{"choices": {"a": 1}}',
        "",
    ],
)
def test_a_reply_that_is_not_the_expected_envelope_is_still_an_llm_error(monkeypatch, body):
    """The cut-off check reads the reply first; it must not turn an odd one into another error."""
    _install(monkeypatch, _Response(body=body))

    with pytest.raises(LLMError):
        LLMClient(_settings(llm_base_url=OPENROUTER)).complete_json("s", "u")


def test_an_error_status_is_an_llm_error_and_is_not_retried_as_a_cut_off(monkeypatch):
    sent = _install(monkeypatch, _Response(status_code=500, body='{"error": "boom"}'))

    with pytest.raises(LLMError, match="500"):
        LLMClient(_settings(llm_base_url=OPENROUTER)).complete_json("s", "u")

    assert len(sent) == 1


# --- an answer in plain text, for when JSON mode is what went wrong ------------------------------
# Measured on a Japanese question with earlier answers in the conversation: in 9 of 32 tries the
# reply was valid JSON whose answer simply stopped (`{"answer": "... (arigatō gozaimasu) means "}`).
# The model had begun a quoted phrase with a bare `"`, which closes the JSON string, and the
# provider's forced-JSON decoding then filled in the rest. Asked for the same thing without
# `response_format`, none of 32 did (and an answer that opens with a quote came back empty).


def test_a_text_answer_is_the_reply_as_written_and_is_not_asked_for_as_json(monkeypatch):
    sent = _install(
        monkeypatch, _reply('  It means "thank you very much".\n\nUsed after a favour.  ')
    )

    text = LLMClient(_settings()).complete_text("sys", "user")

    assert text == 'It means "thank you very much".\n\nUsed after a favour.'
    assert "response_format" not in sent[0]["payload"]
    assert sent[0]["payload"]["messages"] == [
        {"role": "system", "content": "sys"},
        {"role": "user", "content": "user"},
    ]
    assert sent[0]["payload"]["model"] == _settings().llm_model


def test_text_that_looks_like_json_is_still_just_text(monkeypatch):
    _install(monkeypatch, _reply('{"answer": "42"}'))

    assert LLMClient(_settings()).complete_text("s", "u") == '{"answer": "42"}'


def test_a_text_answer_that_comes_back_in_parts_is_joined(monkeypatch):
    body = {
        "choices": [
            {"message": {"content": [{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]}}
        ]
    }
    _install(monkeypatch, _Response(body=json.dumps(body)))

    assert LLMClient(_settings()).complete_text("s", "u") == "ab"


def test_an_empty_text_answer_is_an_empty_string_not_an_error(monkeypatch):
    _install(monkeypatch, _reply(""))

    assert LLMClient(_settings()).complete_text("s", "u") == ""


@pytest.mark.parametrize(
    "response",
    [_Response(status_code=500, body="boom"), _Response(body="not json"), _Response(body="{}")],
)
def test_a_text_answer_that_fails_is_an_llm_error(monkeypatch, response):
    _install(monkeypatch, response)

    with pytest.raises(LLMError):
        LLMClient(_settings()).complete_text("s", "u")


def test_the_key_never_appears_in_a_text_failure(monkeypatch):
    _install(monkeypatch, _Response(status_code=401, body="bad key"))

    with pytest.raises(LLMError) as caught:
        LLMClient(_settings()).complete_text("s", "u")

    assert KEY not in str(caught.value)


def test_a_text_answer_that_runs_out_while_thinking_is_asked_again_with_reasoning_off(monkeypatch):
    sent = _install(monkeypatch, _ran_out(None), _reply("Lucena."))

    text = LLMClient(_settings(llm_base_url=OPENROUTER)).complete_text("s", "u")

    assert text == "Lucena." and len(sent) == 2
    assert "reasoning" not in sent[0]["payload"]
    assert _thinking(sent[1]["payload"]) == {"enabled": False}


def test_a_text_answer_that_runs_out_twice_is_an_error_not_half_an_answer(monkeypatch):
    sent = _install(monkeypatch, _ran_out(None), _ran_out("The Lucena position is the cla"))

    with pytest.raises(LLMError):
        LLMClient(_settings(llm_base_url=OPENROUTER)).complete_text("s", "u")

    assert len(sent) == 2


def test_a_text_answer_can_skip_reasoning_from_the_start_and_has_the_same_room(monkeypatch):
    sent = _install(monkeypatch, _reply("ok"))

    LLMClient(_settings(llm_base_url=OPENROUTER)).complete_text("s", "u", reasoning=False)

    assert _thinking(sent[0]["payload"]) == {"enabled": False}
    assert sent[0]["payload"]["max_tokens"] == ANSWER_TOKENS


def test_another_endpoint_is_never_sent_a_reasoning_field_for_text_either(monkeypatch):
    sent = _install(monkeypatch, _reply("ok"))

    LLMClient(_settings()).complete_text("s", "u", reasoning=False)

    assert "reasoning" not in sent[0]["payload"]


# --- a reply that is not the JSON object asked for ---------------------------------------------
# Measured: the model sometimes answers `["An oxidation state is ..."]` or
# `[{"answer": "Article 21 ..."}]` - JSON, but a list - which was an error shown to the student.
# Those are told apart from a failed request so that the answer can be asked for again as text.


def test_a_reply_that_is_not_json_is_a_format_error(monkeypatch):
    _install(monkeypatch, _reply("Sure! The answer is 42."))

    with pytest.raises(LLMFormatError):
        LLMClient(_settings()).complete_json("s", "u")


@pytest.mark.parametrize(
    "content", ['["an answer"]', '[{"answer": "an answer"}]', '"just text"', "42"]
)
def test_json_that_is_not_an_object_is_a_format_error(monkeypatch, content):
    _install(monkeypatch, _reply(content))

    with pytest.raises(LLMFormatError):
        LLMClient(_settings()).complete_json("s", "u")


def test_a_format_error_is_still_an_llm_error():
    assert issubclass(LLMFormatError, LLMError)


@pytest.mark.parametrize(
    "response",
    [_Response(status_code=500, body="boom"), _Response(body="not json"), _Response(body="{}")],
)
def test_a_failed_request_or_a_broken_envelope_is_not_a_format_error(monkeypatch, response):
    _install(monkeypatch, response)

    with pytest.raises(LLMError) as caught:
        LLMClient(_settings()).complete_json("s", "u")

    assert not isinstance(caught.value, LLMFormatError)


def test_a_transport_failure_is_not_a_format_error(monkeypatch):
    def boom(url, **kwargs):
        raise requests.ConnectionError("down")

    monkeypatch.setattr("pli.llm.client.requests.post", boom)

    with pytest.raises(LLMError) as caught:
        LLMClient(_settings()).complete_json("s", "u")

    assert not isinstance(caught.value, LLMFormatError)
