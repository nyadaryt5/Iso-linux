#!/usr/bin/env python3
"""Unit tests for the MicroAI providers (no network calls to Google/providers).

OpenAI-compatible endpoints and the Gemini streaming RPC are exercised against
local mock servers so that credential pools, auto routing, health rotation,
brain injection, and response parsing can be verified without credentials.
"""

from __future__ import annotations

# Keep the tree clean: never write .pyc files next to the targets under test.
import sys

sys.dont_write_bytecode = True

import contextlib
import hashlib
import http.server
import importlib.machinery
import importlib.util
import io
import json
import os
import re
import tempfile
import threading
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_loader = importlib.machinery.SourceFileLoader(
    "micro_ai", str(ROOT / "src/normal/usr/local/bin/micro-ai")
)
_spec = importlib.util.spec_from_loader("micro_ai", _loader)
assert _spec is not None
micro_ai = importlib.util.module_from_spec(_spec)
_loader.exec_module(micro_ai)

FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        return
    FAILURES.append(f"{name}: {detail}")


def with_temp_state(tmp: str) -> None:
    micro_ai.STATE_DIR = Path(tmp)
    micro_ai.STATE_FILE = Path(tmp) / "state.json"
    micro_ai._STATE = None
    micro_ai._STATE_DIRTY = False


# ---- cookie parsing --------------------------------------------------------

sample_export = [
    {"name": "SAPISID", "value": "TEST-SAPISID", "domain": ".google.com"},
    {"name": "__Secure-1PSID", "value": "TEST-PSID", "domain": ".google.com"},
    {"name": "NID", "value": "TEST-NID=with=equals", "domain": ".google.com"},
]


def test_cookie_json_list() -> None:
    cookies = micro_ai.cookies_from_json(sample_export)
    check("json-list-count", len(cookies) == 3, str(cookies))
    hdr = micro_ai.cookie_header_from_cookies(cookies)
    check(
        "json-list-header",
        "SAPISID=TEST-SAPISID" in hdr
        and "__Secure-1PSID=TEST-PSID" in hdr
        and "TEST-NID=with=equals" in hdr,
        hdr,
    )


def test_cookie_full_chrome_export_shape() -> None:
    export = [
        {
            "name": "SAPISID",
            "value": "EXPORT-SAPISID",
            "domain": ".google.com",
            "hostOnly": False,
            "path": "/",
            "secure": True,
            "httpOnly": False,
            "session": False,
            "expirationDate": 1822475597.569,
            "storeId": None,
        },
        {"name": "__Secure-1PSID", "value": "EXPORT-PSID", "httpOnly": True},
        {"name": "_ga", "value": "GA1.1.123", "domain": ".gemini.google.com"},
    ]
    cookies = micro_ai.parse_cookie_input(json.dumps(export))
    check(
        "full-export",
        cookies.get("SAPISID") == "EXPORT-SAPISID"
        and cookies.get("__Secure-1PSID") == "EXPORT-PSID"
        and cookies.get("_ga") == "GA1.1.123",
        str(cookies),
    )


def test_cookie_json_dict_and_nested() -> None:
    cookies = micro_ai.cookies_from_json({"SAPISID": "A", "NID": "B"})
    check("json-dict", cookies == {"SAPISID": "A", "NID": "B"}, str(cookies))
    nested = micro_ai.cookies_from_json(
        {"cookies": [{"name": "SAPISID", "value": "C"}]}
    )
    check("json-nested", nested == {"SAPISID": "C"}, str(nested))


def test_cookie_header_string() -> None:
    cookies = micro_ai.parse_cookie_input(
        "SAPISID=TEST-SAPISID; __Secure-1PSID=TEST-PSID"
    )
    check(
        "header-string",
        cookies.get("SAPISID") == "TEST-SAPISID"
        and cookies.get("__Secure-1PSID") == "TEST-PSID",
        str(cookies),
    )


def test_cookie_netscape_and_file() -> None:
    netscape = (
        "# Netscape HTTP Cookie File\n"
        ".google.com\tTRUE\t/\tTRUE\t2147483647\tSAPISID\tFILE-SAPISID\n"
        "#HttpOnly_.google.com\tTRUE\t/\tTRUE\t2147483647\tNID\tFILE-NID\n"
    )
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "cookies.txt"
        path.write_text(netscape, encoding="utf-8")
        cookies = micro_ai.parse_cookie_input(str(path))
        check(
            "netscape-file",
            cookies.get("SAPISID") == "FILE-SAPISID"
            and cookies.get("NID") == "FILE-NID",
            str(cookies),
        )


def test_cookie_missing_sapisid_detected() -> None:
    cookies = micro_ai.parse_cookie_input("NID=only")
    check(
        "missing-sapisid",
        micro_ai.extract_cookie(cookies, "SAPISID") is None,
        str(cookies),
    )


def test_multiple_cookie_accounts_from_dir() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        (directory / "account-a.json").write_text(
            json.dumps(
                [
                    {"name": "SAPISID", "value": "AAAA", "domain": ".google.com"},
                    {"name": "__Secure-1PSID", "value": "AAA-PSID"},
                ]
            ),
            encoding="utf-8",
        )
        (directory / "account-b.json").write_text(
            json.dumps(
                [
                    {"name": "SAPISID", "value": "BBBB", "domain": ".google.com"},
                    {"name": "__Secure-1PSID", "value": "BBB-PSID"},
                ]
            ),
            encoding="utf-8",
        )
        (directory / "broken.json").write_text(
            json.dumps([{"name": "NID", "value": "no-sapisid"}]), encoding="utf-8"
        )
        config = {"AI_GEMINI_COOKIE_DIR": str(directory)}
        accounts = micro_ai.get_gemini_accounts(config)
        check("multi-account-count", len(accounts) == 2, str(len(accounts)))
        labels = sorted(str(a["label"]) for a in accounts)
        check("multi-account-labels", labels == ["account-a.json", "account-b.json"], str(labels))
        check(
            "multi-account-sapisid",
            all(micro_ai.extract_cookie(a["cookies"], "SAPISID") for a in accounts),
        )


# ---- API key pools ---------------------------------------------------------


def test_multiple_api_keys_env_and_file() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        key_file = Path(tmp) / "api-keys"
        key_file.write_text("keyB\n# comment\nkeyC\n", encoding="utf-8")
        old = os.environ.get("MICRO_AI_API_KEYS")
        os.environ["MICRO_AI_API_KEYS"] = "keyA,keyB"
        try:
            keys = micro_ai.get_api_keys(
                {"AI_API_KEYS_FILE": str(key_file)}
            )
        finally:
            if old is None:
                os.environ.pop("MICRO_AI_API_KEYS", None)
            else:
                os.environ["MICRO_AI_API_KEYS"] = old
        check("multi-key-order", keys == ["keyA", "keyB", "keyC"], str(keys))


# ---- health state rotation -------------------------------------------------


def test_credential_health_rotation() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        with_temp_state(tmp)
        bad = micro_ai.credential_id("api", "bad-key")
        good = micro_ai.credential_id("api", "good-key")
        micro_ai.mark_credential_failure("api", bad)
        micro_ai.mark_credential_failure("api", bad)
        ordered = micro_ai.order_credentials("api", ["bad-key", "good-key"])
        check("health-order", ordered[0][0] == "good-key", str(ordered))
        micro_ai.mark_credential_success("api", bad)
        entry = micro_ai._entry("api", bad)
        check(
            "health-recover",
            entry.get("failures") == 0 and "unhealthy_until" not in entry,
            str(entry),
        )
        ordered = micro_ai.order_credentials("api", ["bad-key", "good-key"])
        check(
            "health-all-considerable",
            set(credential for credential, _ in ordered) == {"bad-key", "good-key"},
            str(ordered),
        )


# ---- SAPISIDHASH and model map ---------------------------------------------


def test_sapisid_hash() -> None:
    ts = 1234567890
    expected = hashlib.sha1(
        f"{ts} TEST-SAPISID https://gemini.google.com".encode("utf-8")
    ).hexdigest()
    check(
        "sapisid-hash",
        micro_ai.sapisid_hash("TEST-SAPISID", ts) == f"SAPISIDHASH {ts}_{expected}",
        micro_ai.sapisid_hash("TEST-SAPISID", ts),
    )


def test_model_map() -> None:
    hex_id, mode = micro_ai.gemini_model_config("gemini-3.6-flash")
    check("model-flash", hex_id == "fbb127bbb056c959" and mode == 1, str((hex_id, mode)))
    hex_id, mode = micro_ai.gemini_model_config("gemini-auto")
    check("model-auto", hex_id is None and mode == 1, str((hex_id, mode)))
    try:
        micro_ai.gemini_model_config("gemini-no-such-model")
        check("model-unknown", False, "unknown model was accepted")
    except micro_ai.GeminiError:
        check("model-unknown", True)


# ---- response parsing -------------------------------------------------------


def synthetic_wrb_line(texts: list[str], filler: str = "x" * 300) -> str:
    inner = [None] * 10
    inner[4] = [[None, [text]] for text in texts]
    return json.dumps([["wrb.fr", "id", json.dumps(inner), None, filler]])


def test_response_extraction() -> None:
    raw = (
        synthetic_wrb_line(["Hello from Gemini. ", "Hello from Gemini. More."])
        + "\n"
        + synthetic_wrb_line(["Hello from Gemini. More."])
    )
    text = micro_ai.extract_gemini_text(raw)
    check("extract-last", text == "Hello from Gemini. More.", text)


def test_code_artifact_cleanup() -> None:
    dirty = "Answer:\n```python?code_reference&code_event_index=0\nprint(1)\n```\ntail"
    text = micro_ai.clean_gemini_text(dirty)
    check("code-artifact", text == "Answer:\ntail", repr(text))
    fallback = micro_ai.GEMINI_CODE_MARKER_RE.sub(
        r"```\1",
        "```python?code_reference&code_event_index=0\nprint(1)\n```",
    )
    check("code-marker-fallback", fallback.startswith("```python"), fallback)


# ---- mock helpers -----------------------------------------------------------


class OpenAIMockHandler(http.server.BaseHTTPRequestHandler):
    seen: list[dict[str, object]] = []
    models: list[str] = [
        "claude-3-5-haiku",
        "gpt-4o-mini",
        "gpt-4o",
        "gemini-2.0-flash",
        "custom-model",
    ]
    serve_models = True

    def log_message(self, format: str, *args: object) -> None:
        return

    def do_GET(self) -> None:  # noqa: N802
        if self.path.rstrip("/").endswith("/models") and self.serve_models:
            payload = json.dumps(
                {"object": "list", "data": [{"id": m} for m in self.models]}
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_error(404)

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8", "replace")
        auth = self.headers.get("Authorization", "")
        idx = len(OpenAIMockHandler.seen)
        OpenAIMockHandler.seen.append({"auth": auth, "body": body, "index": idx})
        if "Bearer bad-key" in auth:
            payload = json.dumps({"error": {"message": "invalid key"}}).encode("utf-8")
            self.send_response(401)
        else:
            payload = json.dumps(
                {"choices": [{"message": {"content": "ok from good-key"}}]}
            ).encode("utf-8")
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def run_mock(handler: type[http.server.BaseHTTPRequestHandler]):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread, server.server_address[1]


def stop_mock(server: http.server.ThreadingHTTPServer, thread: threading.Thread) -> None:
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)


# ---- auto routing -----------------------------------------------------------


def test_auto_routing_fallback() -> None:
    OpenAIMockHandler.seen = []
    server, thread, port = run_mock(OpenAIMockHandler)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            with_temp_state(tmp)
            old_keys = os.environ.get("MICRO_AI_API_KEYS")
            os.environ["MICRO_AI_API_KEYS"] = "bad-key,good-key"
            try:
                config = {
                    "AI_ROUTES": "api",
                    "AI_API_URL": f"http://127.0.0.1:{port}/v1/chat/completions",
                    "AI_API_MODEL": "test-model",
                    "AI_BRAIN": "0",
                    "AI_API_KEYS_FILE": str(Path(tmp) / "missing-keys"),
                    "AI_LOCAL_URL": "http://127.0.0.1:1/v1/chat/completions",
                    "AI_LOCAL_MODEL": "x",
                }
                stdout = io.StringIO()
                stderr = io.StringIO()
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    rc = micro_ai.ask_auto("hello", config)
                check("auto-rc", rc == 0, f"rc={rc} stderr={stderr.getvalue()}")
                check(
                    "auto-output",
                    stdout.getvalue().strip() == "ok from good-key",
                    stdout.getvalue(),
                )
                check(
                    "auto-route-note",
                    "MicroAI route: api" in stderr.getvalue(),
                    stderr.getvalue(),
                )
                auths = [str(e["auth"]) for e in OpenAIMockHandler.seen]
                check(
                    "auto-fallback-order",
                    auths == ["Bearer bad-key", "Bearer good-key"],
                    str(auths),
                )
            finally:
                if old_keys is None:
                    os.environ.pop("MICRO_AI_API_KEYS", None)
                else:
                    os.environ["MICRO_AI_API_KEYS"] = old_keys
    finally:
        stop_mock(server, thread)


def test_auto_skips_missing_providers() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        with_temp_state(tmp)
        old_keys = os.environ.get("MICRO_AI_API_KEYS")
        os.environ.pop("MICRO_AI_API_KEYS", None)
        try:
            config = {
                "AI_ROUTES": "api,gemini,local",
                "AI_BRAIN": "0",
                "AI_API_KEYS_FILE": str(Path(tmp) / "missing"),
                "AI_GEMINI_COOKIE_DIR": str(Path(tmp) / "no-cookies"),
                "AI_LOCAL_URL": "http://127.0.0.1:1/v1/chat/completions",
                "AI_LOCAL_MODEL": "x",
            }
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                rc = micro_ai.ask_auto("hello", config)
            check("auto-missing-rc", rc == 1, f"rc={rc}")
            check(
                "auto-missing-notes",
                "no keys" in stderr.getvalue()
                and "no cookie accounts" in stderr.getvalue()
                and "exhausted all providers" in stderr.getvalue(),
                stderr.getvalue(),
            )
        finally:
            if old_keys is not None:
                os.environ["MICRO_AI_API_KEYS"] = old_keys


# ---- automatic model selection -----------------------------------------------


def test_model_preference_and_list() -> None:
    check(
        "model-list",
        micro_ai.list_api_models("http://127.0.0.1:9/v1", "x") == [],
    )
    models = ["a-claude-3-5-haiku", "b-gpt-4o-mini", "c-custom"]
    check(
        "pick-builtin",
        micro_ai.pick_api_model(models, "") == "b-gpt-4o-mini",
        micro_ai.pick_api_model(models, ""),
    )
    router_models = ["claude-3-5-haiku", "minimax-m3-free", "gpt-4o-mini"]
    check(
        "pick-router-free-first",
        micro_ai.pick_api_model(router_models, "") == "minimax-m3-free",
        micro_ai.pick_api_model(router_models, ""),
    )
    check(
        "pick-preference",
        micro_ai.pick_api_model(models, "gpt-4o-mini") == "b-gpt-4o-mini",
        micro_ai.pick_api_model(models, "gpt-4o-mini"),
    )
    check(
        "pick-first-fallback",
        micro_ai.pick_api_model(["zz-only", "aa-only"], "nope") == "zz-only",
    )


def test_model_auto_selection_via_mock() -> None:
    OpenAIMockHandler.seen = []
    server, thread, port = run_mock(OpenAIMockHandler)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            with_temp_state(tmp)
            old_keys = os.environ.get("MICRO_AI_API_KEYS")
            os.environ["MICRO_AI_API_KEYS"] = "good-key"
            try:
                config = {
                    "AI_API_URL": f"http://127.0.0.1:{port}/v1/chat/completions",
                    "AI_API_MODEL": "auto",
                    "AI_MODEL_PREFERENCE": "",
                    "AI_BRAIN": "0",
                    "AI_API_KEYS_FILE": str(Path(tmp) / "missing"),
                }
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    rc = micro_ai.ask_api("hi", config, key="good-key")
                check("auto-model-rc", rc == 0, f"rc={rc}")
                body = json.loads(str(OpenAIMockHandler.seen[-1]["body"]))
                check(
                    "auto-model-picked",
                    body["model"] == "gpt-4o-mini",
                    str(body["model"]),
                )
                # Preference override wins on the cached list.
                config["AI_MODEL_PREFERENCE"] = "gpt-4o-mini"
                with contextlib.redirect_stdout(io.StringIO()):
                    micro_ai.ask_api("hi", config, key="good-key")
                body = json.loads(str(OpenAIMockHandler.seen[-1]["body"]))
                check(
                    "auto-model-preference",
                    body["model"] == "gpt-4o-mini",
                    str(body["model"]),
                )
            finally:
                if old_keys is None:
                    os.environ.pop("MICRO_AI_API_KEYS", None)
                else:
                    os.environ["MICRO_AI_API_KEYS"] = old_keys
    finally:
        stop_mock(server, thread)


def test_model_auto_fallback_when_no_list() -> None:
    OpenAIMockHandler.serve_models = False
    OpenAIMockHandler.seen = []
    server, thread, port = run_mock(OpenAIMockHandler)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            with_temp_state(tmp)
            config = {
                "AI_API_URL": f"http://127.0.0.1:{port}/v1/chat/completions",
                "AI_API_MODEL": "auto",
                "AI_BRAIN": "0",
                "AI_API_KEYS_FILE": str(Path(tmp) / "missing"),
            }
            model = micro_ai.resolve_api_model(config, token="x")
            check("auto-model-fallback", model == "gpt-4o-mini", model)
    finally:
        OpenAIMockHandler.serve_models = True
        stop_mock(server, thread)


def test_gemini_model_resolution() -> None:
    model, downgraded = micro_ai.resolve_gemini_model("auto", True)
    check("gemini-auto-auth", model == "gemini-3.6-flash" and not downgraded, model)
    model, downgraded = micro_ai.resolve_gemini_model("auto", False)
    check("gemini-auto-anon", model == "gemini-3.5-flash-lite" and not downgraded, model)
    model, downgraded = micro_ai.resolve_gemini_model("gemini-3.1-pro", False)
    check("gemini-pro-downgrade", model == "gemini-3.5-flash-lite" and downgraded, model)
    model, downgraded = micro_ai.resolve_gemini_model("gemini-3.6-flash", False)
    check("gemini-flash-ok", model == "gemini-3.6-flash" and not downgraded, model)


# ---- brain self-development ---------------------------------------------------


def test_brain_insight_and_context() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        with_temp_state(tmp)
        make_brain(tmp)
        check("brain-ensure", micro_ai.ensure_brain())
        check(
            "brain-add-insight",
            micro_ai.brain_add_insight("Answer with short paragraphs."),
        )
        check(
            "brain-add-empty",
            not micro_ai.brain_add_insight("   "),
        )
        context = micro_ai.brain_context({"AI_BRAIN": "1"})
        check(
            "brain-context-insights",
            "[Insights]" in context and "short paragraphs" in context,
            context,
        )
        check(
            "brain-learn-flag-on",
            micro_ai.brain_learn_from_answer(
                "Use bullet points when listing.\nSecond line", {"AI_BRAIN_LEARN": "1"}
            ),
        )
        check(
            "brain-learn-flag-off",
            micro_ai.brain_learn_from_answer("x", {"AI_BRAIN_LEARN": "0"}) is False,
        )
        context = micro_ai.brain_context({"AI_BRAIN": "1"})
        check(
            "brain-learn-stored",
            "Use bullet points" in context,
            context,
        )


# ---- brain injection --------------------------------------------------------


def make_brain(tmp: str) -> None:
    micro_ai.BRAIN_DIR = Path(tmp) / "brain"
    micro_ai.BRAIN_IDENTITY = micro_ai.BRAIN_DIR / "identity.md"
    micro_ai.BRAIN_MEMORIES = micro_ai.BRAIN_DIR / "memories.md"
    micro_ai.BRAIN_JOURNAL = micro_ai.BRAIN_DIR / "journal.log"
    micro_ai.BRAIN_INSIGHTS = micro_ai.BRAIN_DIR / "insights.md"


def test_brain_injection() -> None:
    OpenAIMockHandler.seen = []
    server, thread, port = run_mock(OpenAIMockHandler)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            with_temp_state(tmp)
            make_brain(tmp)
            old_keys = os.environ.get("MICRO_AI_API_KEYS")
            os.environ["MICRO_AI_API_KEYS"] = "good-key"
            old_dir = os.environ.get("HOME")
            os.environ["HOME"] = tmp
            try:
                # Seed a memory so the assembled context includes the memory section.
                micro_ai.ensure_brain()
                with micro_ai.BRAIN_MEMORIES.open("a", encoding="utf-8") as memories:
                    memories.write("- 2026-01-01 — owner prefers concise answers\n")
                context = micro_ai.brain_context({"AI_BRAIN": "1"})
                check(
                    "brain-context-built",
                    "Persistent memory" in context
                    and "owner prefers concise answers" in context,
                    context,
                )
                config = {
                    "AI_API_URL": f"http://127.0.0.1:{port}/v1/chat/completions",
                    "AI_API_MODEL": "test-model",
                    "AI_BRAIN": "1",
                    "AI_API_KEYS_FILE": str(Path(tmp) / "missing-keys"),
                }
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    rc = micro_ai.ask_api("remember me", config, key="good-key")
                check("brain-rc", rc == 0, f"rc={rc}")
                last = OpenAIMockHandler.seen[-1]
                payload = json.loads(str(last["body"]))
                system = payload["messages"][0]["content"]
                check(
                    "brain-system-prompt",
                    "Persistent memory" in system and "remember me" in payload["messages"][1]["content"],
                    system[:200],
                )
            finally:
                if old_keys is None:
                    os.environ.pop("MICRO_AI_API_KEYS", None)
                else:
                    os.environ["MICRO_AI_API_KEYS"] = old_keys
                if old_dir is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = old_dir
    finally:
        stop_mock(server, thread)


# ---- Gemini round trip ------------------------------------------------------


class GeminiMockHandler(http.server.BaseHTTPRequestHandler):
    seen: dict[str, object] = {}

    def log_message(self, format: str, *args: object) -> None:
        return

    def do_GET(self) -> None:  # noqa: N802
        if self.path.startswith("/app"):
            body = (
                '<html><head>/* {"cfb2h":'
                '"boq_assistant-bard-web-server_20260805.16_p0",'
                '"SNlM0e":"test-xsrf-token:1788000000000"} */</head>'
                "<body>mock</body></html>"
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        payload = self.rfile.read(length).decode("utf-8", "replace")
        inner = [None] * 10
        inner[4] = [[None, ["The mock Gemini answer."]]]
        body = json.dumps(
            [["wrb.fr", "mock-rpc-id" + ("x" * 256), json.dumps(inner), None]]
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        GeminiMockHandler.seen = {
            "path": self.path,
            "authorization": self.headers.get("Authorization", ""),
            "cookie": self.headers.get("Cookie", ""),
            "model_header": self.headers.get("x-goog-ext-525001261-jspb", ""),
            "session_header": self.headers.get("x-goog-ext-525005358-jspb", ""),
            "payload": payload,
        }


def test_gemini_round_trip() -> None:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), GeminiMockHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        port = server.server_address[1]
        with tempfile.TemporaryDirectory() as tmp:
            with_temp_state(tmp)
            make_brain(tmp)
            old_app = micro_ai.GEMINI_APP_URL
            old_endpoint = micro_ai.GEMINI_ENDPOINT
            micro_ai.GEMINI_APP_URL = f"http://127.0.0.1:{port}/app"
            micro_ai.GEMINI_ENDPOINT = (
                f"http://127.0.0.1:{port}/_/BardChatUi/data/"
                "assistant.lamda.BardFrontendService/StreamGenerate"
            )
            micro_ai._APP_TOKENS.clear()
            old_env = os.environ.get("MICRO_AI_GEMINI_COOKIES")
            os.environ["MICRO_AI_GEMINI_COOKIES"] = json.dumps(sample_export)
            try:
                stdout = io.StringIO()
                stderr = io.StringIO()
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    rc = micro_ai.ask_gemini(
                        "hello world from tests",
                        {
                            "AI_GEMINI_MODEL": "gemini-3.6-flash",
                            "AI_GEMINI_COOKIE_FILE": "",
                            "AI_GEMINI_COOKIE_DIR": str(Path(tmp) / "none"),
                            "AI_BRAIN": "0",
                        },
                    )
                check("roundtrip-rc", rc == 0, f"rc={rc} stderr={stderr.getvalue()}")
                check(
                    "roundtrip-output",
                    stdout.getvalue().strip() == "The mock Gemini answer.",
                    stdout.getvalue(),
                )
                seen = GeminiMockHandler.seen
                auth = str(seen.get("authorization", ""))
                check(
                    "roundtrip-auth",
                    re.fullmatch(r"SAPISIDHASH \d+_[0-9a-f]{40}", auth) is not None,
                    auth,
                )
                cookie = str(seen.get("cookie", ""))
                check(
                    "roundtrip-cookie",
                    "SAPISID=TEST-SAPISID" in cookie
                    and "__Secure-1PSID=TEST-PSID" in cookie,
                    cookie,
                )
                model_header = str(seen.get("model_header", ""))
                check(
                    "roundtrip-model-header",
                    '"fbb127bbb056c959"' in model_header,
                    model_header,
                )
                payload = str(seen.get("payload", ""))
                form = urllib.parse.parse_qs(payload)
                check(
                    "roundtrip-at",
                    form.get("at") == ["test-xsrf-token:1788000000000"],
                    payload[:400],
                )
                check("roundtrip-freq", "f.req" in form, payload[:400])
                outer = json.loads(form["f.req"][0])
                inner = json.loads(outer[1])
                check(
                    "roundtrip-prompt",
                    inner[0][0] == "hello world from tests",
                    str(inner[0])[:200],
                )
                check(
                    "roundtrip-bl",
                    "bl=boq_assistant-bard-web-server_20260805.16_p0"
                    in str(seen.get("path", "")),
                    str(seen.get("path", "")),
                )
            finally:
                micro_ai.GEMINI_APP_URL = old_app
                micro_ai.GEMINI_ENDPOINT = old_endpoint
                if old_env is None:
                    os.environ.pop("MICRO_AI_GEMINI_COOKIES", None)
                else:
                    os.environ["MICRO_AI_GEMINI_COOKIES"] = old_env
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def main() -> int:
    test_cookie_json_list()
    test_cookie_full_chrome_export_shape()
    test_cookie_json_dict_and_nested()
    test_cookie_header_string()
    test_cookie_netscape_and_file()
    test_cookie_missing_sapisid_detected()
    test_multiple_cookie_accounts_from_dir()
    test_multiple_api_keys_env_and_file()
    test_credential_health_rotation()
    test_sapisid_hash()
    test_model_map()
    test_response_extraction()
    test_code_artifact_cleanup()
    test_auto_routing_fallback()
    test_auto_skips_missing_providers()
    test_model_preference_and_list()
    test_model_auto_selection_via_mock()
    test_model_auto_fallback_when_no_list()
    test_gemini_model_resolution()
    test_brain_insight_and_context()
    test_brain_injection()
    test_gemini_round_trip()
    if FAILURES:
        print("MicroAI unit test failures:", file=sys.stderr)
        for failure in FAILURES:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print("MicroAI unit tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
