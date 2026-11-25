"""Unit tests that run without Azure: sign-in handling and the security filter."""

import base64
import json
import os
import sys
from pathlib import Path

os.environ.update(
    AZURE_SEARCH_ENDPOINT="https://example.search.windows.net",
    AZURE_SEARCH_INDEX="policies",
    AZURE_OPENAI_ENDPOINT="https://example.openai.azure.com",
    AZURE_OPENAI_CHAT_DEPLOYMENT="chat",
    AZURE_OPENAI_EMBED_DEPLOYMENT="embed",
    GROUP_STAFF_ID="staff-guid",
    GROUP_HR_ID="hr-guid",
)
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import main  # noqa: E402
import rag  # noqa: E402

client = TestClient(main.app)


def principal(*groups: str) -> dict:
    claims = [{"typ": "groups", "val": g} for g in groups]
    encoded = base64.b64encode(json.dumps({"claims": claims}).encode()).decode()
    return {"X-MS-CLIENT-PRINCIPAL": encoded, "X-MS-CLIENT-PRINCIPAL-NAME": "user@example.com"}


@pytest.fixture(autouse=True)
def no_dev_groups(monkeypatch):
    monkeypatch.delenv("DEV_GROUPS", raising=False)


def test_requests_without_sign_in_are_rejected():
    assert client.get("/api/me").status_code == 401
    assert client.post("/api/ask", json={"question": "hello there"}).status_code == 401


def test_groups_are_read_from_easy_auth_header_and_unknown_groups_ignored():
    body = client.get("/api/me", headers=principal("hr-guid", "some-other-group")).json()
    assert body == {"name": "user@example.com", "groups": ["HR"]}


def test_user_without_demo_groups_gets_no_answer_and_azure_is_never_called(monkeypatch):
    def fail(*_args, **_kwargs):
        raise AssertionError("Azure should not be called")

    monkeypatch.setattr(rag, "embed", fail)
    monkeypatch.setattr(rag, "search_client", fail)
    body = client.post("/api/ask", json={"question": "What is the pay band?"}, headers=principal("other")).json()
    assert body["answerable"] is False
    assert body["citations"] == []


def test_search_is_filtered_by_the_users_groups(monkeypatch):
    captured = {}

    class FakeSearch:
        def search(self, **kwargs):
            captured.update(kwargs)
            return []

    monkeypatch.setattr(rag, "embed", lambda texts: [[0.0] * 3])
    monkeypatch.setattr(rag, "search_client", lambda: FakeSearch())
    rag.retrieve("question", ["staff-guid", "not-a-demo-group"])
    assert captured["filter"] == "groups/any(g: search.in(g, 'staff-guid', ','))"


def test_question_length_is_limited():
    response = client.post("/api/ask", json={"question": "x" * 501}, headers=principal("staff-guid"))
    assert response.status_code == 422
