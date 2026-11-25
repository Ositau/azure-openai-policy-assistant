"""Chunk the policy documents, embed them and (re)build the search index.

Each chunk carries a `groups` field listing the Entra ID groups allowed to read it.
Run after `terraform apply`:  python scripts/ingest.py
"""

from __future__ import annotations

import os
import re

import tf_env

tf_env.load()

from azure.search.documents.indexes import SearchIndexClient  # noqa: E402
from azure.search.documents.indexes.models import (  # noqa: E402
    HnswAlgorithmConfiguration,
    SearchableField,
    SearchField,
    SearchFieldDataType,
    SearchIndex,
    SimpleField,
    VectorSearch,
    VectorSearchProfile,
)

import rag  # noqa: E402

DOCS = tf_env.ROOT / "docs" / "policies"
EMBED_DIMS = 1536


def parse(path) -> tuple[dict, list[tuple[str, str]]]:
    text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
    front, body = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.S).groups()
    meta = dict(line.split(": ", 1) for line in front.splitlines())
    sections = re.split(r"^## ", body, flags=re.M)[1:]
    return meta, [(s.split("\n", 1)[0].strip(), s.split("\n", 1)[1].strip()) for s in sections]


def build_index() -> SearchIndex:
    return SearchIndex(
        name=os.environ["AZURE_SEARCH_INDEX"],
        fields=[
            SimpleField(name="id", type=SearchFieldDataType.String, key=True),
            SimpleField(name="doc_id", type=SearchFieldDataType.String, filterable=True),
            SearchableField(name="title", type=SearchFieldDataType.String),
            SearchableField(name="section", type=SearchFieldDataType.String),
            SearchableField(name="content", type=SearchFieldDataType.String, analyzer_name="en.microsoft"),
            SimpleField(name="groups", type=SearchFieldDataType.Collection(SearchFieldDataType.String), filterable=True),
            SearchField(
                name="embedding",
                type=SearchFieldDataType.Collection(SearchFieldDataType.Single),
                searchable=True,
                vector_search_dimensions=EMBED_DIMS,
                vector_search_profile_name="default",
            ),
        ],
        vector_search=VectorSearch(
            algorithms=[HnswAlgorithmConfiguration(name="hnsw")],
            profiles=[VectorSearchProfile(name="default", algorithm_configuration_name="hnsw")],
        ),
    )


def main() -> None:
    staff, hr = os.environ["GROUP_STAFF_ID"], os.environ["GROUP_HR_ID"]
    access = {"staff": [staff, hr], "hr": [hr]}

    chunks = []
    for path in sorted(DOCS.glob("*.md")):
        meta, sections = parse(path)
        for i, (section, content) in enumerate(sections):
            chunks.append({
                "id": f"{path.stem}-{i}",
                "doc_id": path.stem,
                "title": meta["title"],
                "section": section,
                "content": content,
                "groups": access[meta["audience"]],
            })

    vectors = rag.embed([f"{c['title']} - {c['section']}\n{c['content']}" for c in chunks])
    for chunk, vector in zip(chunks, vectors):
        chunk["embedding"] = vector

    index_client = SearchIndexClient(os.environ["AZURE_SEARCH_ENDPOINT"], rag._credential())
    name = os.environ["AZURE_SEARCH_INDEX"]
    if name in list(index_client.list_index_names()):
        index_client.delete_index(name)
    index_client.create_index(build_index())

    results = rag.search_client().upload_documents(chunks)
    ok = sum(r.succeeded for r in results)
    restricted = sum(1 for c in chunks if c["groups"] == [hr])
    print(f"Indexed {ok}/{len(chunks)} chunks from {len(list(DOCS.glob('*.md')))} documents "
          f"({restricted} chunks HR-only).")


if __name__ == "__main__":
    main()
