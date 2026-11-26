"""Self-test endpoint and the fault switch. No Azure needed: the clients are faked."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

import test_app  # noqa: F401  (sets the environment and import path)
import main
import rag
import selftest
from fastapi.testclient import TestClient

client = TestClient(main.app)


class FakeSearch:
    def __init__(self, endpoint, index_name, credential):
        self.index_name = index_name

    def search(self, **kwargs):
        if self.index_name == selftest.MISSING_INDEX:
            raise RuntimeError("The index 'policies-missing' for service 'srch-x' was not found.")
        return [{"doc_id": "annual-leave"}]


def fake_openai(calls):
    def create(model, input):
        calls.append(model)
        if model == selftest.MISSING_DEPLOYMENT:
            raise RuntimeError("DeploymentNotFound: The API deployment for this resource does not exist.")
        return SimpleNamespace(data=[SimpleNamespace(embedding=[0.1, 0.2])])

    return SimpleNamespace(embeddings=SimpleNamespace(create=create))


@pytest.fixture(autouse=True)
def fakes(monkeypatch):
    calls: list[str] = []
    monkeypatch.setattr(selftest, "SearchClient", FakeSearch)
    monkeypatch.setattr(rag, "openai_client", lambda: fake_openai(calls))
    monkeypatch.setattr(rag, "_credential", lambda: None)
    monkeypatch.setattr(selftest, "SLOW_SECONDS", 0)
    monkeypatch.setattr(main, "SELFTEST_MIN_INTERVAL", 0)
    monkeypatch.delenv("FAULT_MODE", raising=False)
    return calls


def test_selftest_needs_no_sign_in_and_returns_no_policy_content():
    r = client.get("/api/selftest")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok" and body["fault_mode"] == "off" and body["results"] == 1
    assert "annual-leave" not in r.text


@pytest.mark.parametrize("mode", ["errors", "ai"])
def test_fault_modes_fail_with_500_and_log_the_real_error(monkeypatch, caplog, mode):
    monkeypatch.setenv("FAULT_MODE", mode)
    with caplog.at_level("ERROR", logger="policy_assistant.selftest"):
        r = client.get("/api/selftest")
    assert r.status_code == 500
    assert "Self-test failed" in r.text and "policies-missing" not in r.text  # no internals in the response
    logged = caplog.text
    assert ("was not found" in logged) if mode == "errors" else ("DeploymentNotFound" in logged)


def test_ai_mode_calls_the_missing_deployment(monkeypatch, fakes):
    monkeypatch.setenv("FAULT_MODE", "ai")
    client.get("/api/selftest")
    assert fakes == [selftest.MISSING_DEPLOYMENT]


def test_slow_mode_still_succeeds(monkeypatch):
    monkeypatch.setenv("FAULT_MODE", "slow")
    r = client.get("/api/selftest")
    assert r.status_code == 200 and r.json()["fault_mode"] == "slow"


def test_unknown_mode_means_off(monkeypatch):
    monkeypatch.setenv("FAULT_MODE", "delete-everything")
    assert client.get("/api/selftest").json()["fault_mode"] == "off"


def test_rate_limit(monkeypatch):
    monkeypatch.setattr(main, "SELFTEST_MIN_INTERVAL", 60)
    main._last_selftest["at"] = 0.0
    assert client.get("/api/selftest").status_code == 200
    assert client.get("/api/selftest").status_code == 429


def test_fault_mode_never_affects_signed_in_users(monkeypatch):
    """The chat endpoint doesn't read FAULT_MODE: a user without demo groups still gets the normal answer."""
    monkeypatch.setenv("FAULT_MODE", "errors")
    r = client.post("/api/ask", json={"question": "What is the pay band?"}, headers=test_app.principal("other"))
    assert r.status_code == 200 and r.json()["answerable"] is False
