# MASTER BUILD PROMPT — Enterprise Incident Intelligence Platform

**You are a senior full-stack AI engineer.** Build a production-quality, hackathon-ready application called the **Enterprise Incident Intelligence Platform**: a LangGraph-orchestrated, multi-agent system that turns IT incidents into a closed-loop learning system, with a Human-in-the-Loop (HIL) SME approval gate, a shared Enterprise Knowledge Service (Agentic RAG), a FastAPI backend, a SQLite database, and a React frontend.

This prompt is your single source of truth for scope, architecture, and sequencing. Two additional files will be pasted alongside this prompt as context — **treat them as binding specifications, not suggestions**:

1. `schema.sql` — the finalized database schema (Postgres-flavored; you must adapt it to SQLite — instructions below).
2. `rag_prompt.txt` — the exact build spec for the Enterprise Knowledge Service (the shared RAG microservice). Build it precisely as written there, **plus** the multi-index extension described in Phase 3 below.

Do not deviate from the workflow branching logic described here — it is transcribed exactly from the team's finalized `Final_Workflow.txt` and `AI_Agents_Specification_Updated.md`. If anything in this prompt seems ambiguous, prefer the interpretation that keeps the two branch diagrams (below) faithful to the original documents over any generic incident-management pattern you may know.

---

## 0. Non-Negotiable Constraints

- **No Hugging Face, no `sentence-transformers`, no CrossEncoder, no Torch, no local model downloads — anywhere in the codebase**, not just the RAG service. All LLM and embedding calls go through the TCS GenAI Lab endpoint (config below).
- **Database: SQLite only.** No Postgres, no external DB server.
- **Backend: FastAPI + Uvicorn.**
- **Orchestration: LangGraph** for both the main workflow graph and the RAG service's internal retrieval graph.
- **Frontend: React** (Vite + React Router; Tailwind + a component library such as shadcn/ui for a professional look — your choice of exact packages, but the visual bar is "enterprise SaaS dashboard," not "hackathon prototype").
- **You do not generate incident data, RAG documents, or seed content.** Your job is to build the ingestion tooling and seed-loader scripts. The user will supply the actual dataset (matching `schema.sql`) and the actual documents (per category) themselves.
- **Never hardcode the TCS API key.** Always read it from an environment variable and fail fast with a clear error if it's missing.
- **Build in phases (Section 9).** Do not start a phase until the previous phase's deliverables and exit criteria are met. At the end of each phase, list the files created/changed and how to verify them before continuing.

---

## 1. Model & Embedding Configuration (shared by every component)

This is the **one and only** LLM/embedding configuration for the entire codebase — the RAG service, all six reasoning agents, and any judge/groundedness calls. Create it once as a shared module (e.g. `common/llm_client.py`) and import it everywhere; do not re-implement this client in multiple places.

```python
import os
os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")  # must run before numpy/faiss import anywhere

import httpx
import requests
from langchain_openai import ChatOpenAI

BASE_URL = "https://genailab.tcs.in/v1"
LLM_MODEL = "azure/genailab-maas-gpt-4o-mini"
EMBEDDING_MODEL = "azure/genailab-maas-text-embedding-3-large"
EMBEDDING_DIM = 3072

API_KEY = os.getenv("TCS_GENAI_API_KEY")
if not API_KEY:
    raise RuntimeError("TCS_GENAI_API_KEY is required")

# SSL verification is disabled because this is required in the hackathon lab environment.
_http_client = httpx.Client(verify=False)

llm = ChatOpenAI(
    base_url=BASE_URL,
    model=LLM_MODEL,
    api_key=API_KEY,
    http_client=_http_client,
    temperature=0.0,
    max_tokens=1024,
)

def get_embedding(text: str) -> list[float]:
    response = requests.post(
        f"{BASE_URL}/embeddings",
        headers={"Authorization": f"Bearer {API_KEY}", "Content-Type": "application/json"},
        json={"model": EMBEDDING_MODEL, "input": text},
        verify=False,
        timeout=60,
    )
    response.raise_for_status()
    return response.json()["data"][0]["embedding"]
```

Notes:
- Agents that need a lower/higher temperature (e.g. slightly more generative Fair Resolution copy) should instantiate a **second** `ChatOpenAI` client in the same module with an overridden `temperature`, reusing the same `http_client`, `base_url`, `api_key`, and `model` — never duplicate the boilerplate.
- Every network call to the TCS endpoint must go through `verify=False` exactly as shown; do not "fix" this by re-enabling SSL verification.
- Suppress the resulting `InsecureRequestWarning` once, centrally, using `urllib3.disable_warnings(...)`.

---

## 2. Database Layer

### 2.1 Source of truth
`schema.sql` (pasted alongside this prompt) is the finalized schema. It is written in Postgres-flavored SQL. Convert it to valid SQLite DDL using these exact rules — do not change any table, column, or constraint semantics, only the dialect:

| Postgres construct in schema.sql | SQLite equivalent |
|---|---|
| `SERIAL PRIMARY KEY` | `INTEGER PRIMARY KEY AUTOINCREMENT` |
| `VARCHAR(n)` | keep as-is — SQLite uses type affinity and ignores the length, no need to strip it |
| `BOOLEAN ... DEFAULT FALSE` | `INTEGER NOT NULL DEFAULT 0` (store 0/1) |
| `TIMESTAMP` | keep column type name `TIMESTAMP` (SQLite affinity handles it), store values as ISO-8601 text (`YYYY-MM-DD HH:MM:SS`) |
| `DATE` | keep as `DATE`, store as ISO-8601 text (`YYYY-MM-DD`) |
| `CHECK (...)` constraints | keep verbatim — fully supported |
| `REFERENCES` foreign keys | keep verbatim, but foreign keys are **not enforced by default** in SQLite — see 2.2 |
| `CREATE INDEX` statements | keep verbatim |

Produce `db/schema_sqlite.sql` as the translated file. Every table (`deployments`, `incidents`, `application_logs`, `kb_articles`, `ai_analysis`, `sme_approval`, `prevention_actions`, `workflow_execution`) and every index listed in `schema.sql` must be present.

### 2.2 Connection module
Build `db/connection.py`:
- A `get_connection()` context manager that opens the SQLite file (e.g. `db/incident_platform.db`), sets `row_factory = sqlite3.Row`, and runs `PRAGMA foreign_keys = ON;` and `PRAGMA journal_mode = WAL;` on every connection.
- A `db/init_db.py` CLI script that drops (if `--reset` flag passed) and (re)creates all tables from `schema_sqlite.sql`. Running `python -m db.init_db` with no data must produce a valid, empty, fully-constrained database.

### 2.3 Seed loader (tooling only — no data)
Build `db/seed_loader.py`, a CLI that:
- Accepts a path to a directory of CSV or JSON files (one per table: `incidents.csv`, `deployments.csv`, `application_logs.csv`, `kb_articles.csv` — and optionally pre-populated `ai_analysis.csv` / `prevention_actions.csv` for historical incidents).
- Validates required columns against `schema_sqlite.sql`, converts types, and bulk-inserts respecting FK order (`deployments` → `incidents` → `application_logs`/`kb_articles` → `ai_analysis` → `sme_approval`/`prevention_actions`).
- Reports row counts inserted per table and any rows skipped due to validation errors, with reasons.
- Is idempotent-safe: running twice on the same file should not duplicate primary keys (upsert on primary key, or a `--truncate-first` flag).
- **Do not fabricate or hallucinate any row content.** This script only loads what the user provides.

---

## 3. Enterprise Knowledge Service (Shared Agentic RAG) — Phase 3 build target

Build this as a **standalone FastAPI microservice** (its own folder, its own port, e.g. `rag_service/`) exactly per the attached `rag_prompt.txt`, with one required extension described below. `rag_prompt.txt` already specifies: the offline ingestion pipeline (PDF → chunk → embed → FAISS + BM25), the online query graph (query processor → HyDE → hybrid retrieval → LLM retrieval judge → CRAG → context builder → grounded generator → groundedness judge), the exact LangGraph state fields, the CRAG retry thresholds, the FastAPI contract (`/health`, `/ingest`, `/query`), the Windows FAISS/OpenMP guard, and the full requirements pin list. Build all of that as written, with no scope reduction.

### 3.1 Required extension: multi-category indexes (shared knowledge base)

`AI_Agents_Specification_Updated.md` requires the Enterprise Knowledge Service to store **independently indexed document collections**, one per category, so agents can target the right knowledge source instead of one undifferentiated index. This is an addition on top of the base `rag_prompt.txt` spec — implement it as follows:

- Define five fixed categories, each with its **own** FAISS index, BM25 index, and chunk store, persisted under `indexes/<category>/{faiss.index, bm25.pkl, chunks.pkl}`:
  - `historical_incidents` — Historical Incident Index
  - `kb_articles` — Knowledge Base (KB) Index
  - `policies` — Policy Index
  - `deployments` — Deployment Index (architecture/deployment docs)
  - `ai_validated_knowledge` — AI Validated Knowledge Index (written to only by the Knowledge Publishing Service after SME approval — see Section 5.8)
- `POST /ingest` accepts a required `category` field (one of the five above) and ingests into that category's index only. PDF ingestion via `python -m retrieval.ingest --category <name> --data-dir data/<name>/` must also work standalone, per `rag_prompt.txt`'s CLI requirement — extend the CLI to accept `--category`.
- `POST /query` accepts a required `categories: list[str]` field (one or more of the five). When more than one category is given, run the hybrid retrieval + judge + CRAG pipeline **per category**, then merge the judged chunks across categories by score before context building — do not simply concatenate unjudged results. Keep every other part of the retrieval graph (HyDE generation happens once per query, not once per category) exactly as `rag_prompt.txt` specifies.
- The response JSON keeps the exact shape from `rag_prompt.txt`, plus a `category` field on each item in `retrieved_chunks` / `judge_chunks` so callers know which index a chunk came from.
- This microservice is called over HTTP by every reasoning agent in Section 5 (never imported as a Python module) — build a small typed client (`common/rag_client.py`) in the main backend with `query(query: str, categories: list[str]) -> RagQueryResult` and `ingest(...)` wrappers, so agents never construct raw HTTP calls themselves.

### 3.2 Do not
Do not let this service know anything about incidents, SQL, or the operational database — it is domain-agnostic per `rag_prompt.txt`, and the incident-specific meaning of each category lives entirely in how the main platform calls it.

---

## 4. Main Workflow: Exact Branching Logic

This is the authoritative state machine, transcribed from `Final_Workflow.txt`. Implement it as a single LangGraph `StateGraph` in the main backend (not the RAG service's internal graph — that's a separate, nested graph invoked over HTTP as described above).

### 4.1 Entry
`User clicks "Analyze Incident"` on an incident → `POST /api/incidents/{incident_number}/analyze` → orchestrator creates a `workflow_execution` row (`workflow_status='Running'`, `current_agent='recurrence_detection'`) and starts the graph, keyed by a LangGraph **thread_id = incident_number**, using a **SQLite-backed checkpointer** (`langgraph.checkpoint.sqlite.SqliteSaver`, pointed at its own checkpoint DB file) so the graph can be interrupted and resumed across HTTP requests — this is how Human-in-the-Loop works (Section 4.5).

### 4.2 Node 1 — Recurrence Detection Agent (`recurrence_detection`)
Per `AI_Agents_Specification_Updated.md`:
- Reads: `incidents` (current incident row), `ai_analysis`, `prevention_actions`, plus queries the Enterprise Knowledge Service against `historical_incidents` and `ai_validated_knowledge` categories.
- Internal steps: generate a search query from the incident (short_description + description + category + service + configuration_item) → query RAG → retrieve similar incidents → use the LLM to verify whether the retrieved root causes genuinely match this incident's symptoms (do not trust vector similarity alone) → check whether `ai_analysis` already has a row for this incident number (or a verified-matching prior incident) → check `prevention_actions` status for that prior incident.
- Writes: none.
- Routes to exactly one of three cases, set on state as `case: "historical" | "recurring" | "new"`.

Route definitions (must match exactly):
- **Case 1 — Historical Incident**: similar past incidents exist in the knowledge base with a verified matching root cause, but **no `ai_analysis` row exists yet** for this specific incident. → go to `evidence_collection`.
- **Case 2 — Recurring Incident**: an `ai_analysis` row **already exists** for this exact incident (or an LLM-verified duplicate). → go to `retrieve_previous_investigation`.
- **Case 3 — Completely New Incident**: no similar incident found in the knowledge base at all. → go to `request_sme_documents`.

### 4.3 Case 1 branch — full automated pipeline
```
evidence_collection → timeline_reconstruction → root_cause_analysis
→ recovery_recommendation → fair_resolution_and_prevention
→ sme_approval (HIL PAUSE) → create_prevention_action → assign_action_owner
→ knowledge_publishing → END
```
Each node's responsibilities, reads/writes, and I/O are specified per-agent in Section 5. This is also the branch Case 2's "IMPLEMENTED" sub-path re-enters (Section 4.4).

### 4.4 Case 2 branch — recurring incident (the "Watcher" check)
```
retrieve_previous_investigation → check_prevention_actions → {branch on status}
```
- `retrieve_previous_investigation`: load the prior `ai_analysis` row(s) for this incident/pattern (root_cause, recovery, fair_resolution, prevention) — no LLM call needed, pure DB read.
- `check_prevention_actions`: read the latest `prevention_actions` row tied to the prior incident.
  - **NOT IMPLEMENTED** (`status` is `'Not Started'` or `'In Progress'`): the recurrence is explained by the fix never having been completed — no need to re-investigate root cause.
    ```
    → generate_governance_report_and_notify → END
    ```
    This node produces a short report ("Incident recurred because prevention action #X was never completed"), stores/returns it for the UI, and (stub) "notifies" the action owner — a log line and a UI notification banner is sufficient for the hackathon; do not build real email/Slack integration unless asked.
  - **IMPLEMENTED** (`status == 'Completed'`): the fix was supposedly done but the problem happened again — this is a genuine prevention failure, and this is the platform's core "Watcher" capability (flagging that a fix stopped working).
    ```
    → escalate_sme_prevention_failed (HIL PAUSE — acknowledgement gate)
    → reopen_investigation
    → evidence_collection → timeline_reconstruction → root_cause_analysis
      → recovery_recommendation → fair_resolution_and_prevention
    → sme_approval (HIL PAUSE)
    → update_prevention_action → knowledge_publishing → END
    ```
    `update_prevention_action` must mark the previously-`Completed` action's `verified` column `'No'` (the fix is now known to have failed) as part of this step, in addition to whatever new prevention action(s) the re-run pipeline produces.

### 4.5 Case 3 branch — completely new incident (cold start)
```
request_sme_documents (HIL PAUSE — manual submission gate)
→ knowledge_publishing → END
```
There is no similar prior knowledge to ground an automated RCA against, so the platform does **not** run the six-agent pipeline for Case 3. Instead it pauses and asks the SME to manually supply: Ticket, Logs, Emails, RCA, Resolution, KB article, SOP — see the UI spec in Section 6.4. Once submitted, those documents/fields go straight to Knowledge Publishing (Section 5.8) so future incidents of this type become Case 1 or Case 2.

### 4.6 Human-in-the-Loop mechanics
Every node marked **HIL PAUSE** above must:
1. Update `workflow_execution.workflow_status = 'Waiting'` and `current_agent` to the paused node's name.
2. Use LangGraph's interrupt mechanism (`interrupt_before` on the next node, or an explicit `interrupt()` call inside the node, depending on your LangGraph version) so the graph run returns control to the API without proceeding.
3. Expose a resume endpoint (Section 6) that injects the human's decision into graph state and calls `graph.invoke(None, config={"configurable": {"thread_id": incident_number}})` (or the update+resume pattern for your LangGraph version) to continue from exactly where it paused.
4. On graph completion, set `workflow_execution.workflow_status = 'Completed'`.

### 4.7 sme_approval node — resolving the schema vs. diagram ambiguity
`Final_Workflow.txt` shows one "SME Approval" box validating Root Cause, Recovery, Fair Resolution, and Prevention together. But `sme_approval` in `schema.sql` constrains `stage` to exactly two values, `'RCA'` and `'Prevention'`. Implement it as **one SME-facing screen with two independent decisions**, so both the diagram's intent (single approval step in the workflow) and the schema's structure (two stages) are honored:
- Stage `RCA` covers **Root Cause + Recovery**.
- Stage `Prevention` covers **Fair Resolution + Prevention**.
- The SME can approve or reject each stage independently, with separate comments, in the same screen.
- The graph node blocks until **both** stage decisions are recorded (two rows written to `sme_approval`, both referencing the same `ai_analysis.analysis_id`).
- If **either** stage is rejected, do not proceed to `create_prevention_action`/`update_prevention_action`; instead route to a terminal `rejected` state, set `ai_analysis.status='Rejected'`, and surface the SME's comments back on the incident page so the analysis can be manually revisited (do not silently re-run the agents automatically on rejection — this is a hackathon scope decision, state it in code comments).
- If both are approved, set `ai_analysis.status='Approved'` and continue.

---

## 5. Agent Specifications

Build each agent as its own module under `agents/` (e.g. `agents/recurrence_detection.py`, `agents/evidence_collection.py`, ...), each exposing a single function with the signature `def run(state: WorkflowState) -> dict` (a partial state update) so they can be wired directly as LangGraph nodes. Every reasoning agent (all except Evidence Collection and Timeline Reconstruction) must use the shared `llm` client from Section 1 and the shared RAG client from Section 3.1 — never call the TCS endpoint directly from an agent module.

### 5.1 Recurrence Detection Agent
Covered fully in 4.2. No DB writes.

### 5.2 Evidence Collection Agent
- Reads: `incidents` (full row), `application_logs` (all rows for `incident_number`, ordered by `log_timestamp`), `deployments` (row matching `incidents.related_deployment`, when it's a real deployment ID and not free text — handle the "no recent deployment" free-text case gracefully, per the schema's own comment on that column).
- **Performs no reasoning** — pure data collection and correlation by incident number, per spec. No LLM call in this node.
- Output: an `EvidencePackage` (typed dict/dataclass) with `incident`, `logs`, `deployment` — held in graph state, not persisted to a new table (the schema has no evidence table; it's a workflow-state artifact only).

### 5.3 Timeline Reconstruction Agent
- Input: `EvidencePackage` from state.
- Responsibilities: sort logs chronologically, correlate deployment start/end against log timestamps, identify major milestones (deployment → first error → first customer-facing symptom → incident creation), and build a structured timeline (ordered list of `{timestamp, label, source, detail}` events).
- This can be done with deterministic Python (sorting/correlation) plus a light LLM pass to produce human-readable milestone labels — keep the LLM's job narrow (labeling/summarizing), not fact invention.
- Output: `Timeline` — held in graph state.

### 5.4 Root Cause Analysis Agent
- Inputs: `Timeline`, Enterprise Knowledge Service.
- Reads (RAG categories): `historical_incidents`, `kb_articles`, `policies`, `deployments`, `ai_validated_knowledge` — query across all five, or a relevant subset, depending on incident category.
- Responsibilities: compare against similar historical incidents/KB entries, validate the technical cause against the evidence timeline, produce an explainable RCA (a clear causal narrative, not just a label) with citations back to which KB/historical/policy source(s) supported it.
- **Writes:** `ai_analysis.root_cause` (create the `ai_analysis` row here if one doesn't exist yet for this incident, `status='Pending'`).

### 5.5 Recovery Recommendation Agent
- Inputs: Root Cause, Enterprise Knowledge.
- Reads (RAG categories): `kb_articles`, `policies`, `deployments`, `ai_validated_knowledge`.
- Responsibilities: generate a step-by-step recovery plan, recommend operational actions, produce a verification checklist (concrete, testable steps to confirm the fix worked).
- **Writes:** `ai_analysis.recovery`.

### 5.6 Fair Resolution & Prevention Agent
- Inputs: Root Cause, Recovery, Enterprise Policies (RAG `policies` category).
- Responsibilities — generate **both**:
  - Fair Resolution: compensation recommendation (if applicable), SLA handling guidance, a draft customer communication.
  - Prevention: monitoring improvements, SOP updates, automation opportunities, architecture improvements — written so it can seed a `prevention_actions` row (a clear, assignable recommendation).
- **Writes:** `ai_analysis.fair_resolution`, `ai_analysis.prevention`.

### 5.7 SME Approval + Prevention Action Creation (orchestrator-managed, not an LLM agent)
Per Section 4.7. After both stages approved:
- `create_prevention_action` (Case 1) / `update_prevention_action` (Case 2 re-investigation): insert into `prevention_actions` (`recommendation` derived from `ai_analysis.prevention`, `owner`, `due_date`, `status='Not Started'`, `verified='No'`). Owner assignment ("Assign Action Owner" in the diagram) can be a simple UI field the SME fills in on the same approval screen, or a dropdown of demo owners/teams — your call, keep it simple.

### 5.8 Knowledge Publishing Service (not an agent — deterministic pipeline)
- Triggered after: Case 1/2 prevention action creation, or Case 3 manual SME document submission.
- Converts the approved investigation (or the SME's manually supplied Case 3 documents) into a structured knowledge document: Incident Summary, Root Cause, Recovery, Prevention, Lessons Learned, Metadata (incident number, category, service, dates).
- Pipeline: semantic chunking → embeddings → publish into the Enterprise Knowledge Service's `ai_validated_knowledge` category via `POST /ingest` (Section 3.1) — this is what closes the loop and is what future Recurrence Detection / Root Cause Analysis calls will retrieve against.
- No database reasoning — this service does not query or write SQL tables beyond reading the already-approved `ai_analysis` row it's publishing from.

### 5.9 Workflow Orchestrator (LangGraph — not an agent)
Reads/writes only `workflow_execution`: creates the row on start, updates `current_agent` and `workflow_status` on every node transition (`Running` while active, `Waiting` while paused on HIL, `Completed` at `END`), and `updated_at` on every write.

---

## 6. FastAPI Backend — Endpoint Contract

Single FastAPI app (`backend/main.py`) with routers per domain. Enable CORS for the React dev server origin. All responses are JSON; use Pydantic models for every request/response body — no raw dicts returned from route handlers.

### 6.1 Dashboard
- `GET /api/dashboard/summary` → `{ total_incidents, open, in_progress, closed, analyzed_by_ai, pending_sme_approval, recurring_count, new_count, prevention_actions: {not_started, in_progress, completed, verified_yes, verified_no} }`

### 6.2 Incidents
- `GET /api/incidents?q=&status=&priority=&category=&page=&page_size=` → paginated list with key columns for the list view (incident_number, state, priority, category, service, opened_at, short_description, has_ai_analysis).
- `GET /api/incidents/{incident_number}` → full detail: incident row + related deployment + latest `ai_analysis` (if any) + `sme_approval` history + `prevention_actions` + latest `workflow_execution` status.
- `POST /api/incidents/{incident_number}/analyze` → starts (or resumes if already `Waiting`) the workflow graph; returns current `workflow_execution` state.
- `GET /api/incidents/{incident_number}/workflow` → polling endpoint: `{current_agent, workflow_status, case, reasoning_trace}` — `reasoning_trace` is an ordered list of `{node, started_at, finished_at, summary}` built up as the graph runs, so the UI can render a live step-by-step trace (Section 6.5 gives the UI requirement this feeds).

### 6.3 SME actions (HIL)
- `POST /api/incidents/{incident_number}/sme/approve` — body `{stage: "RCA"|"Prevention", decision: "Approved"|"Rejected", comments, approved_by}` → writes `sme_approval`, resumes graph once both stages for the current `analysis_id` are decided.
- `POST /api/incidents/{incident_number}/sme/acknowledge-prevention-failure` — resumes the `escalate_sme_prevention_failed` pause in the Case 2 "IMPLEMENTED" branch.
- `POST /api/incidents/{incident_number}/sme/manual-documentation` — body with the Case 3 fields (ticket text, logs summary, emails summary, rca, resolution, kb article text, sop text) → resumes `request_sme_documents`, feeds Knowledge Publishing.

### 6.4 Prevention actions
- `GET /api/prevention-actions?owner=&status=`
- `PATCH /api/prevention-actions/{action_id}` — update `status`, `verified`, `owner`, `due_date`.

### 6.5 Users (hackathon persona switcher — no real auth)
- `GET /api/users` → a small static list (config file or in-memory list, `schema.sql` has no users table — do not add one, keep this UI-only) of demo personas, e.g. `{id, name, role}`, used purely to populate `approved_by` on SME actions and to label "acting as" in the UI.

---

## 7. React Frontend

### 7.1 Global shell
- Top nav bar: app name/logo, primary nav (Dashboard, Incidents, Prevention Actions), and a **user-switcher dropdown at the top right** listing personas from `GET /api/users`; the selected persona's name is used as `approved_by` wherever the current user takes an SME action. Persist selection in React state (or `sessionStorage`) — no backend session needed.
- Consistent status/priority badges used everywhere: priority (P1 red, P2 amber, P3 blue), incident state (New/Open/In Progress/Closed), workflow status (Running/Waiting/Completed with distinct colors), prevention status, and `verified` yes/no.

### 7.2 Dashboard page
Cards/charts sourced from `GET /api/dashboard/summary`: total/open/closed/in-progress incident counts, incidents analyzed by AI, incidents pending SME approval, recurring-vs-new breakdown, and prevention action status breakdown (a small bar or donut chart is enough — use Recharts). Make this feel like a real ops dashboard: clear numbers up top, a chart or two below, recent-activity list at the bottom (most recently analyzed incidents).

### 7.3 Incidents list page
- Search box (searches incident number and short description via `q`), filter controls for status, priority, and category, paginated table.
- Clicking a row routes to the Incident Detail page.

### 7.4 Incident Detail page
Tabbed or sectioned layout:
- **Overview** — all core incident fields from `incidents`, plus linked deployment summary if present.
- **Evidence & Timeline** — rendered once the workflow has run past `timeline_reconstruction`; a simple vertical timeline component matching the milestone example in the spec (Deployment → Authentication Failure → Customer Complaint → Incident Created).
- **AI Analysis** — Root Cause, Recovery, Fair Resolution, Prevention, each shown as it becomes available (poll `GET /api/incidents/{id}/workflow` while `workflow_status='Running'`).
- **Workflow Status** — a step indicator showing the current node against the branch the incident took (Case 1/2/3), driven by `reasoning_trace`; a prominent **"Analyze Incident"** button when no workflow has started yet, disabled/replaced with a status pill once running.
- **SME Approval panel** — appears only when `workflow_status='Waiting'`. Renders the correct form for whichever pause point is active:
  - `sme_approval`: two decision blocks (RCA+Recovery / Fair Resolution+Prevention) each with Approve/Reject + comments, per persona.
  - `escalate_sme_prevention_failed`: an acknowledgement panel explaining the prior fix failed, with an "Acknowledge & Re-open Investigation" button.
  - `request_sme_documents`: a structured form for Ticket/Logs/Emails/RCA/Resolution/KB/SOP text fields, with a "Submit & Publish to Knowledge Base" button.
- **Prevention Actions** — list of `prevention_actions` tied to this incident with inline owner/status/verified editing.

### 7.5 Prevention Actions page
Cross-incident table of all prevention actions with owner/status filters, so a team lead can see everything assigned to them across incidents.

### 7.6 Visual bar
Use the `frontend-design` skill's guidance for typography, spacing, and color choices before writing component CSS/Tailwind config — this should look like a polished internal enterprise tool, not default Bootstrap/Material.

---

## 8. Offline Tooling (user-run, not agent-run)

These are CLIs/scripts you build; **the user runs them with their own data** after your build is complete.

- **RAG ingestion**: `python -m retrieval.ingest --category <historical_incidents|kb_articles|policies|deployments|ai_validated_knowledge> --data-dir data/<category>/` (per Section 3.1), one folder per category under a top-level `data/` directory in the RAG service.
- **DB seeding**: `python -m db.seed_loader --data-dir <path> [--truncate-first]` (per Section 2.3).
- Document both clearly in the top-level `README.md` with exact commands, expected folder layout, and what "success" output looks like for each.

---

## 9. Build Phases — execute strictly in this order

For each phase: implement it fully, list every file created/modified, state how to verify it (a command to run and the expected result), and only then move to the next phase.

| Phase | Deliverable | Exit criteria |
|---|---|---|
| **0** | Repo scaffolding: top-level folders (`db/`, `common/`, `rag_service/`, `agents/`, `backend/`, `frontend/`), `.env.example` with `TCS_GENAI_API_KEY`, `README.md` skeleton, `.gitignore` | Folder tree exists; `.env.example` documents every required var |
| **1** | Database layer (Section 2): `db/schema_sqlite.sql`, `db/connection.py`, `db/init_db.py`, `db/seed_loader.py` | `python -m db.init_db --reset` produces a valid empty DB with all 8 tables + indexes; `sqlite3 db/incident_platform.db ".schema"` matches `schema.sql` semantics |
| **2** | Shared model client (Section 1): `common/llm_client.py`, `common/rag_client.py` (stub against Phase 3's not-yet-built service is fine here, finalize signatures) | A one-off script successfully calls `llm.invoke(...)` and `get_embedding(...)` against the real TCS endpoint |
| **3** | Enterprise Knowledge Service (Section 3), as its own runnable FastAPI app on its own port | `/health` returns `{"status":"ok"}`; `POST /ingest` with a sample category + a small local PDF succeeds; `POST /query` against it returns the full response shape from `rag_prompt.txt` plus `category` tags |
| **4** | Six agent modules + Knowledge Publishing (Section 5), each independently unit-callable with a hand-built fake `WorkflowState` (no orchestrator yet) | Each agent module runs standalone against a manually seeded single incident and returns the expected partial-state shape |
| **5** | Workflow Orchestrator (Section 4): `backend/orchestrator/graph.py`, `WorkflowState` schema, `SqliteSaver` checkpointing, HIL interrupt/resume wiring for all three cases | A scripted test drives one incident through Case 1 end-to-end including a pause/resume at `sme_approval`, and separately exercises the Case 2 and Case 3 branch selection logic |
| **6** | FastAPI backend (Section 6): all routers wired to DB + orchestrator + RAG client | Every endpoint in Section 6 is reachable via `curl`/OpenAPI docs (`/docs`) and returns the documented shape against seeded data |
| **7** | React frontend (Section 7) | `npm run dev` serves a working app against the running backend: dashboard loads real numbers, incident search/filter works, an incident can be analyzed end-to-end through the UI including the SME approval form, and Case 2/Case 3 UI paths render correctly given appropriately seeded test incidents |
| **8** | Offline tooling polish + README (Section 8) | README walks a new user from `git clone` to a fully running app (both backend services + frontend) plus their own seeding/ingestion, with copy-pasteable commands |
| **9** | Integration pass: run all three cases end-to-end against user-seeded data, fix any cross-phase glue issues found | All three branch diagrams in Section 4 are demonstrably reachable and correct in the running app |

---

## 10. Engineering Standards (apply throughout, all phases)

- Python: type hints on every function signature, Pydantic models for all API I/O, docstrings on every agent/node explaining its inputs/outputs/writes (mirroring Section 5), structured logging (not bare `print`) with at minimum: node entered/exited, RAG queries issued (query text + categories + returned confidence), DB writes, HIL pause/resume events.
- No secrets in code or version control; everything sensitive comes from environment variables documented in `.env.example`.
- Keep the RAG service and the main backend as two independently runnable processes communicating over HTTP — do not import RAG internals into the main backend.
- Prefer explicit, named LangGraph node functions over lambdas so the graph is easy to read and debug.
- Every DB write goes through parameterized queries — no string-formatted SQL, anywhere.

---

**Attachments to paste alongside this prompt:** `schema.sql`, `rag_prompt.txt`.
