"""Policy Assistant web app (FastAPI).

Sign-in is handled in front of the app by Azure Container Apps built-in
authentication (Entra ID). The platform passes the signed-in user's claims,
including group IDs, in the X-MS-CLIENT-PRINCIPAL header.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

import rag
import selftest

if os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    from azure.monitor.opentelemetry import configure_azure_monitor

    configure_azure_monitor(logger_name="policy_assistant")

audit = logging.getLogger("policy_assistant.audit")
audit.setLevel(logging.INFO)
health = logging.getLogger("policy_assistant.selftest")
health.setLevel(logging.INFO)
SELFTEST_MIN_INTERVAL = 2.0  # seconds between self-tests, so the open endpoint can't run up a bill
_last_selftest = {"at": 0.0}

app = FastAPI(title="Policy Assistant", docs_url=None, redoc_url=None)
STATIC = Path(__file__).parent / "static"


class Question(BaseModel):
    question: str = Field(min_length=3, max_length=500)


def current_user(request: Request) -> tuple[str, list[str]]:
    """Return (display name, group ids) for the signed-in user."""
    principal = request.headers.get("X-MS-CLIENT-PRINCIPAL")
    if principal:
        claims = json.loads(base64.b64decode(principal)).get("claims", [])
        groups = [c["val"] for c in claims if c.get("typ") == "groups"]
        name = request.headers.get("X-MS-CLIENT-PRINCIPAL-NAME", "unknown")
        return name, groups

    # Local development only: DEV_GROUPS=staff or DEV_GROUPS=staff,hr.
    # Never set in Azure, so a request without the platform header is rejected there.
    dev = os.getenv("DEV_GROUPS")
    if dev:
        by_name = {v.lower(): k for k, v in rag.known_groups().items()}
        return "local-developer", [by_name[g.strip().lower()] for g in dev.split(",") if g.strip().lower() in by_name]

    raise HTTPException(status_code=401, detail="Not signed in")


@app.get("/")
def index() -> FileResponse:
    return FileResponse(STATIC / "index.html")


@app.get("/healthz")
def healthz() -> dict:
    return {"status": "ok"}


@app.get("/api/selftest")
def run_selftest() -> dict:
    """Fixed check against the real services, open without sign-in (see selftest.py).

    Excluded from Entra ID sign-in in the Container Apps auth settings, like a health check.
    Returns no policy content and is rate-limited.
    """
    now = time.monotonic()
    if now - _last_selftest["at"] < SELFTEST_MIN_INTERVAL:
        raise HTTPException(status_code=429, detail="Too many self-tests; try again in a moment.")
    _last_selftest["at"] = now

    fault = selftest.mode()
    try:
        result = selftest.run(fault)
    except Exception:
        # Logged with the full Azure error, so monitoring (and the incident assistant) can see the real cause.
        health.exception("selftest_failed", extra={"fault_mode": fault})
        raise HTTPException(status_code=500, detail="Self-test failed.") from None
    health.info("selftest_ok", extra={"fault_mode": fault, "latency_ms": result["ms"]})
    return result


@app.get("/api/me")
def me(request: Request) -> dict:
    name, groups = current_user(request)
    names = rag.known_groups()
    return {"name": name, "groups": [names[g] for g in groups if g in names]}


@app.post("/api/ask")
def ask(body: Question, request: Request) -> dict:
    name, groups = current_user(request)
    started = time.perf_counter()
    result = rag.ask(body.question, groups)
    elapsed_ms = round((time.perf_counter() - started) * 1000)

    # Audit record: who asked what, and which documents the answer relied on.
    audit.info(
        "policy_question",
        extra={
            "user": name,
            "user_groups": ",".join(rag.known_groups().get(g, "") for g in groups if g in rag.known_groups()),
            "question": body.question,
            "answerable": result.answerable,
            "cited_docs": ",".join(c["doc_id"] for c in result.citations),
            "retrieved_docs": ",".join(dict.fromkeys(result.retrieved_doc_ids)),
            "prompt_tokens": result.prompt_tokens,
            "completion_tokens": result.completion_tokens,
            "latency_ms": elapsed_ms,
        },
    )
    return {
        "answer": result.answer,
        "answerable": result.answerable,
        "citations": result.citations,
        "latency_ms": elapsed_ms,
    }
