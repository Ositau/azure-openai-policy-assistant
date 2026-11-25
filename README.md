# Policy Assistant: secure RAG on Azure OpenAI

An internal assistant that answers staff questions about company policy, with a citation for every answer, built the way a regulated business needs it:

- **Answers only from documents the user is allowed to see.** Each document is tagged with Entra ID security groups; search results are filtered by the signed-in user's groups *before* anything reaches the model. HR-only documents can't leak, whatever the question.
- **No API keys anywhere.** Azure OpenAI and AI Search have key authentication switched off; the app uses a managed identity, the pipeline uses workload identity federation.
- **EU data residency.** Models are deployed as `DataZoneStandard` in Sweden Central, so prompts are processed inside the EU.
- **Audit trail.** Every question is logged to Application Insights with the user, the documents cited and the token cost.
- **Tested before release.** A 22-question evaluation set runs in the pipeline; a release is blocked if any answer is wrong or any HR document is retrieved for a Staff user.

The company ("Kestrel Bridge Finance") and its policies are fictional, written for this demo.

## Architecture

```
 Staff / HR user
      │  Entra ID sign-in (Container Apps built-in auth, groups claim)
      ▼
 Azure Container Apps ── FastAPI + chat page ── managed identity ──┐
      │                                                            │ RBAC only
      │ 1. hybrid search (keyword + vector), filtered by groups    ▼
      ├──────────────────────────────────────────────► Azure AI Search
      │ 2. answer from the permitted sources only, JSON with citations
      ├──────────────────────────────────────────────► Azure OpenAI (gpt-4o-mini, EU data zone)
      │ 3. audit record
      └──────────────────────────────────────────────► Application Insights / Log Analytics
```

| Layer | Path | Deployed by |
|---|---|---|
| Bootstrap: state storage, Entra ID groups and sign-in app, pipeline identity, Key Vault, registry, least-privilege RBAC | `infra/bootstrap` | A person, once |
| Platform: Azure OpenAI, AI Search, Container Apps, monitoring, managed identity | `infra` | `pipelines/infra.yml` |
| Application: image build, re-index, evaluation gate, release | `app`, `scripts`, `eval` | `pipelines/app.yml` |

## Azure DevOps pipelines

**Infrastructure** (`pipelines/infra.yml`): Validate (fmt, validate, TFLint) → Plan → manual approval → Apply. The approved list of changes is saved, and Apply re-plans and stops if anything differs, so what runs is what was approved (plan files aren't published because the project is public).

**Application** (`pipelines/app.yml`): unit tests → image built in ACR → re-index and run the evaluation set (quality gate) → roll out to Container Apps.

**Pipeline identity, least privilege:** no client secret (workload identity federation), no Microsoft Graph permissions (Entra ID objects are in the bootstrap layer), Contributor on one resource group only, and Role Based Access Control Administrator restricted by an ABAC condition to six named roles.

Setup steps: [SETUP.md](SETUP.md).

## How answers are produced

1. The question is embedded (`text-embedding-3-small`) and run as a hybrid keyword + vector query against AI Search, with `groups/any(...)` filtering on the user's Entra ID groups.
2. The top sections go to `gpt-4o-mini` with instructions to answer only from them, using a strict JSON schema: `answer`, `answerable`, `citations`.
3. If the sources don't cover the question, the assistant says so instead of guessing.

## Evaluation

`eval/questions.json` covers normal questions, Staff users asking about HR-only content (including a prompt-injection attempt), questions the policies don't cover, and HR users asking HR questions. `scripts/evaluate.py` checks the cited document, key facts in the answer, and that no HR document is even retrieved for a Staff user.

## Run locally

```bash
python -m venv .venv && .venv/bin/pip install -r app/requirements.txt pytest httpx
pytest tests                         # no Azure needed
# against a deployed environment (az login, Terraform backend initialised):
python scripts/ingest.py && python scripts/evaluate.py
cd app && DEV_GROUPS=staff uvicorn main:app --reload
```

## Cost

Within a few pounds a month while running: AI Search free tier, Container Apps scale to zero, ACR Basic, pay-per-token models. Tear down with the steps in SETUP.md.
