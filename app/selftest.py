"""Self-test with a switchable fault, so monitoring and the AI incident assistant can be tested safely.

GET /api/selftest runs one fixed check against the real services: embed a short question with
Azure OpenAI and run one search as a Staff user. It returns no policy content, only whether
the check worked and how long it took.

FAULT_MODE (an app setting) makes the self-test fail in a realistic way. It affects nothing else:
signed-in users of the chat page are never touched.

  off     normal (default)
  errors  search a missing index          -> real "index not found" error from AI Search
  slow    wait SLOW_SECONDS before checking -> slow responses
  ai      call a missing embedding model   -> real "deployment not found" error from Azure OpenAI
"""

from __future__ import annotations

import os
import time

from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizedQuery

import rag

MODES = ("off", "errors", "slow", "ai")
SLOW_SECONDS = 8
QUESTION = "How many days of annual leave do I get?"
MISSING_INDEX = "policies-missing"
MISSING_DEPLOYMENT = "text-embedding-missing"


def mode() -> str:
    value = os.getenv("FAULT_MODE", "off").strip().lower()
    return value if value in MODES else "off"


def run(fault: str) -> dict:
    started = time.perf_counter()
    if fault == "slow":
        time.sleep(SLOW_SECONDS)

    deployment = MISSING_DEPLOYMENT if fault == "ai" else os.environ["AZURE_OPENAI_EMBED_DEPLOYMENT"]
    vector = rag.openai_client().embeddings.create(model=deployment, input=[QUESTION]).data[0].embedding

    index = MISSING_INDEX if fault == "errors" else os.environ["AZURE_SEARCH_INDEX"]
    client = SearchClient(endpoint=os.environ["AZURE_SEARCH_ENDPOINT"], index_name=index, credential=rag._credential())
    staff = os.environ["GROUP_STAFF_ID"]
    hits = list(
        client.search(
            search_text=QUESTION,
            vector_queries=[VectorizedQuery(vector=vector, k_nearest_neighbors=1, fields="embedding")],
            filter=f"groups/any(g: search.in(g, '{staff}', ','))",
            top=1,
            select=["doc_id"],
        )
    )
    return {"status": "ok", "fault_mode": fault, "results": len(hits), "ms": round((time.perf_counter() - started) * 1000)}
