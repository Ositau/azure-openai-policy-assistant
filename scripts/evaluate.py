"""Run the evaluation set against the live index and model.

Checks per question:
- answer:    answerable, cites the expected document, includes the key facts
- no_access: a Staff user asking about HR-only content gets no answer and no HR document
             is even retrieved (the security filter works before the model sees anything)
- not_found: the documents don't cover it, so the assistant says so instead of guessing

Usage:  python scripts/evaluate.py   (writes eval/results.md)
"""

from __future__ import annotations

import json
import os

import tf_env

tf_env.load()

import rag  # noqa: E402

HR_ONLY = {"pay-and-grading", "disciplinary-investigations"}


def main() -> None:
    questions = json.loads((tf_env.ROOT / "eval" / "questions.json").read_text(encoding="utf-8"))
    ids = {"staff": os.environ["GROUP_STAFF_ID"], "hr": os.environ["GROUP_HR_ID"]}

    rows, passed, tokens = [], 0, 0
    for item in questions:
        result = rag.ask(item["q"], [ids[g] for g in item["as"]])
        tokens += result.prompt_tokens + result.completion_tokens
        cited = {c["doc_id"] for c in result.citations}
        problems = []

        if item["expect"] == "answer":
            if not result.answerable:
                problems.append("no answer")
            if item["doc"] not in cited:
                problems.append(f"did not cite {item['doc']}")
            for fact in item["must_include"]:
                if fact.lower() not in result.answer.lower():
                    problems.append(f"missing '{fact}'")
        else:
            if result.answerable:
                problems.append("answered when it should not")
            if item["expect"] == "no_access" and HR_ONLY & set(result.retrieved_doc_ids):
                problems.append("HR document retrieved for a Staff user")

        ok = not problems
        passed += ok
        rows.append((item, ok, result, "; ".join(problems)))
        print(f"{'PASS' if ok else 'FAIL'}  #{item['id']:>2} [{','.join(item['as'])}] {item['q']}"
              + (f"  -> {'; '.join(problems)}" if problems else ""))

    leaks = sum(1 for item, _, r, _ in rows if "staff" in item["as"] and "hr" not in item["as"]
                and HR_ONLY & set(r.retrieved_doc_ids))
    summary = f"{passed}/{len(rows)} passed, {leaks} HR-only documents retrieved for Staff users, {tokens:,} tokens used"
    print("\n" + summary)

    lines = ["# Evaluation results", "", summary, "",
             "| # | As | Question | Expected | Result | Answer | Sources |",
             "|---|---|---|---|---|---|---|"]
    for item, ok, r, problems in rows:
        sources = ", ".join(f"{c['title']} > {c['section']}" for c in r.citations) or "-"
        answer = r.answer.replace("|", "/").replace("\n", " ")
        status = "pass" if ok else f"FAIL: {problems}"
        lines.append(f"| {item['id']} | {','.join(item['as'])} | {item['q']} | {item['expect']} | {status} | {answer} | {sources} |")
    (tf_env.ROOT / "eval" / "results.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
