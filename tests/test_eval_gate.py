"""The evaluation script is a release gate: it must exit non-zero on any wrong answer or HR leak.

Runs without Azure: rag.ask is replaced with fakes built from eval/questions.json.
"""

import json
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
os.environ.update(
    AZURE_SEARCH_ENDPOINT="https://example.search.windows.net",  # stops tf_env calling terraform
    AZURE_SEARCH_INDEX="policies",
    AZURE_OPENAI_ENDPOINT="https://example.openai.azure.com",
    AZURE_OPENAI_CHAT_DEPLOYMENT="chat",
    AZURE_OPENAI_EMBED_DEPLOYMENT="embed",
    GROUP_STAFF_ID="staff-guid",
    GROUP_HR_ID="hr-guid",
)
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "app"))

import pytest  # noqa: E402

import evaluate  # noqa: E402
from rag import Answer  # noqa: E402

GROUP_NAMES = {"staff-guid": "staff", "hr-guid": "hr"}
# The same question can appear for different groups (Grade 4 as Staff and as HR), so key by both.
QUESTIONS = {(q["q"], tuple(q["as"])): q for q in json.loads((ROOT / "eval" / "questions.json").read_text(encoding="utf-8"))}


def lookup(question: str, group_ids: list[str]) -> dict:
    return QUESTIONS[(question, tuple(GROUP_NAMES[g] for g in group_ids))]


def correct(question: str, group_ids: list[str]) -> Answer:
    """What a perfect assistant would return for each evaluation question."""
    item = lookup(question, group_ids)
    if item["expect"] == "answer":
        return Answer(
            answer=" ".join(item["must_include"]) or "ok",
            answerable=True,
            citations=[{"doc_id": item["doc"], "title": "t", "section": "s"}],
            retrieved_doc_ids=[item["doc"]],
        )
    return Answer(answer="not found", answerable=False)


@pytest.fixture
def run(tmp_path, monkeypatch):
    (tmp_path / "eval").mkdir()
    shutil.copy(ROOT / "eval" / "questions.json", tmp_path / "eval" / "questions.json")
    monkeypatch.setattr(evaluate.tf_env, "ROOT", tmp_path)  # results.md goes to tmp, not the repo

    def _run(fake):
        monkeypatch.setattr(evaluate.rag, "ask", fake)
        return evaluate.main()

    return _run


def test_all_correct_passes_the_gate(run):
    assert run(correct) == 0


def test_one_wrong_answer_fails_the_gate(run):
    def one_wrong(question, group_ids):
        if question.startswith("What is the hotel limit"):
            return Answer(answer="I don't know", answerable=False)
        return correct(question, group_ids)

    assert run(one_wrong) == 1


def test_hr_document_retrieved_for_staff_fails_the_gate(run):
    def leaky(question, group_ids):
        answer = correct(question, group_ids)
        if lookup(question, group_ids)["expect"] == "no_access":
            answer.retrieved_doc_ids = ["pay-and-grading"]  # refused, but the HR document was retrieved
        return answer

    assert run(leaky) == 1
