# Server-rendered UI (phase 5d) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Python, .NET, Go and Rust can render with `frontend=ssr`, a server-rendered UI over the same use case, held to ADR 0005's gates.

**Architecture:** A computed `serve_http = http_api or frontend == 'ssr'` replaces every *server-infrastructure* guard (server deps, bootstrap server start, Dockerfile runtime, compose port, DAST, ZAP rules). `http_api` keeps guarding the JSON routes, their tests and ADR 0004. The UI is a `web` module in each stack's adapters layer. One Node `e2e-ui/` spec (Playwright + axe) runs against every stack's server.

**Tech Stack:** Copier/Jinja; FastAPI + Jinja2; ASP.NET Core Razor Pages; Go `net/http` + `html/template` + `embed`; axum + askama; Playwright + `@axe-core/playwright`; OWASP ZAP baseline.

**Spec:** `docs/superpowers/specs/2026-11-18-ssr-frontend-design.md`

## Global Constraints

- `frontend` choices: TypeScript keeps `none, react, vue, nextjs, angular, react-native`; other stacks offer `none` and `ssr` only. Any other combination fails copier's validator.
- Screen contract (shared spec): `<title>` and `<h1>` "Complete an export"; labels "Job id", "Content"; button "Complete export"; `<p role="status">`; success text `Saved as exports/<id>.csv`; invalid text `Enter a job id (letters, digits, - or _) and some content.`; job id rule `^[A-Za-z0-9_-]{1,64}$`; content non-empty and at most 1,000,000 chars; storage failure text `The export could not be saved.`.
- Routes: `GET /` renders the form; `POST /` (form-encoded) renders the same page with the status (200 success, 400 invalid input, 403 CSRF failure); `GET /static/app.css`; `GET /healthz` always present when `serve_http`.
- Page CSP exactly: `default-src 'none'; style-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'`, plus the same other security headers the HTTP adapter of that stack sends today.
- CSRF (Python/Go/Rust): 32 random bytes, base64url, in cookie `__Host-csrf` (`Path=/; Secure; HttpOnly; SameSite=Strict`) and hidden field `csrf_token`; constant-time compare; reject when `Sec-Fetch-Site` is present and not `same-origin`. .NET uses built-in antiforgery.
- No inline `<script>` or `style=`; no new `IGNORE` line in `.zap/rules.tsv`; no `'unsafe-inline'`.
- Generated `AGENTS.md` stays under 60 lines. Generated shell runs in Git Bash without `jq`.
- Pin new package versions; check licenses (Jinja2 BSD-3, askama MIT/Apache-2.0).
- TypeScript renders must be byte-identical to before for every existing `frontend` value (only guard renames).

## Review Focus

1. `__Host-` cookie on plain `http://127.0.0.1` in Playwright: Chromium must accept it (localhost is a secure context). If it does not, the ruling is: drop the `__Host-` prefix and `Secure` only when the request is not HTTPS, ledgered. Covered by the shared spec's form flow.
2. `ssr` without `http_api`: the server must still start, serve `/healthz`, and the JSON route must be absent (404). Test in each stack's UI task.
3. `ssr` with `http_api`: both on one server; the API's `Content-Security-Policy` stays `default-src 'none'; frame-ancestors 'none'` for API paths while `/` gets the page CSP. Test in render-all (`http_api=true` + `ssr` render for one stack, Python).
4. HTML escaping of user input echoed into the page (job id in the error/status). Shared spec submits `<script>` as job id content and expects the literal text, not an element.
5. Cross-site POST: `page.request.post('/', { headers: { 'Sec-Fetch-Site': 'cross-site' }, form: … })` → 403, and a POST with a mismatched token → 403.

---

### Task 1: Shared plumbing + Python UI

**Files:**
- Modify: `copier.yml` (`frontend` question: `when` removed, choices per stack via `validator`; computed `serve_http`; `cmd.serve`, `cmd.test_ui` for non-TS stacks: `npm --prefix e2e-ui install --no-audit --no-fund && npm --prefix e2e-ui test`; `guardrail_files` `.zap/rules.tsv` under `serve_http`; `stk` layer-rule data if needed)
- Rename: `template/{% if stack == 'typescript' and frontend != 'none' %}e2e-ui{% endif %}/` → `template/{% if frontend != 'none' %}e2e-ui{% endif %}/`; `app.spec.ts` becomes `app.spec.ts.jinja` adding the Review Focus 4–5 tests under `{% if frontend == 'ssr' %}`
- Create: `template/{% if frontend == 'ssr' %}e2e-ui{% endif %}/` siblings `package.json.jinja`, `playwright.config.ts.jinja` (pattern: `template/{% if stack == 'rust' and http_api %}e2e{% endif %}/`; Chromium project; `webServer.command` = `{{ cmd.serve }}`, port 8788, `url` `/healthz`)
- Modify (`http_api` → `serve_http` for server infra only): `.zap` folder name, `ci/…dast.sh` folder name, `Dockerfile.jinja`, `compose.yaml.jinja`, `.github/workflows/ci.yml.jinja` (`dast` job; `ui` job gains non-TS setup: Node 24 + stack toolchain, `npx --prefix e2e-ui playwright install --with-deps chromium`), `.github/dependabot.yml.jinja` (npm ecosystem for `/e2e-ui`), `docs/security/owasp.md.jinja`, Python `pyproject.toml.jinja` (fastapi/uvicorn deps), `.importlinter.jinja` (`web` contract also forbids `jinja2`), `bootstrap/main.py.jinja`
- Create: `template/{% if stack == 'python' %}src{% endif %}/{{ package_name }}/adapters/{% if frontend == 'ssr' %}web{% endif %}/` with `__init__.py`, `routes.py.jinja`, `csrf.py`, `templates/index.html`, `static/app.css`
- Modify: Python HTTP adapter so `create_app(store)` builds the FastAPI app with `/healthz` + headers always, mounts JSON routes when `http_api`, mounts web routes when `ssr` (move app factory if the `http` folder is `http_api`-only: put it in `adapters/{% if serve_http %}http{% endif %}/app.py.jinja`)
- Modify: `docs/adr/0005-frontend.md.jinja` (`ssr` rows per stack: composition root, enforcement table, CSRF, CSP, `cmd.test_ui`), `AGENTS.md.jinja` (UI line already generic; check length), `tests/render-all.sh` (`ssr_checks <stack> <ui-file> <csp-sed> <seed-file> <seed-text> <arch-cmd>`)
- Test: `tests/test_web.py.jinja` (Python unit tests via FastAPI `TestClient`: GET sets cookie and field; POST success; invalid → 400 with message; missing/mismatched token → 403; cross-site → 403; `/exports/x/complete` → 404 without `http_api`)

**Interfaces:**
- Produces: `serve_http` (bool), `cmd.serve` (string), `cmd.test_ui` (string) for every stack with `frontend == 'ssr'`; the shared `e2e-ui/` spec; `ssr_checks` in `tests/render-all.sh`:
  `ssr_checks <stack> <install-cmd> <ui-file> <csp-sed-expression> <application-file> <framework-import-text> <arch-cmd>` — renders `frontend=ssr containerize=true`, runs verify, `cmd.test_ui`, ZAP from `/`, ZAP rejects with CSP line removed, arch rejects the seeded import, axe rejects a seeded unlabeled `<input>` added to the template.

- [ ] **Step 1:** Write `tests/test_web.py.jinja` and the `ssr` tests in `app.spec.ts.jinja` with the Global Constraints' exact strings.
- [ ] **Step 2:** Add `ssr_checks python …` call to `tests/render-all.sh`; run `bash tests/render-all.sh python`. Expected: render fails (`ssr` not a valid choice) → ssr checks FAIL.
- [ ] **Step 3:** Implement copier changes, guard renames, Python web adapter, bootstrap, e2e-ui, CI, ADR, owasp.
- [ ] **Step 4:** Run `bash tests/render-all.sh python` and `bash tests/render-all.sh typescript`. Expected: `ALL PASSED` for both; additionally `diff -r` of a TypeScript render (`frontend=react`, `http_api=true`, `containerize=true`) against `main`'s render shows no differences.
- [ ] **Step 5:** Commit `feat(python): server-rendered UI (frontend=ssr)`.

### Task 2: Go UI

**Files:**
- Create: `template/{% if stack == 'go' %}internal{% endif %}/adapters/{% if frontend == 'ssr' %}web{% endif %}/` with `handler.go.jinja`, `csrf.go`, `templates/index.html`, `static/app.css` (`//go:embed`), `handler_test.go.jinja`
- Modify: `internal/bootstrap/run.go.jinja` (start server when `serve_http`; one `http.ServeMux` mounting API and/or web), `go.mod.jinja`, `.golangci.yml.jinja` (depguard: `html/template` and `net/http` denied in domain/application if not already)
- Modify: `tests/render-all.sh` (`ssr_checks go …`)

**Interfaces:**
- Consumes: `serve_http`, `cmd.serve` (`go run ./cmd/<dir>` — the existing `cmd/{{ go_module }}` entry), `cmd.test_ui`, `ssr_checks` from Task 1.
- Produces: `web.NewHandler(store application.ArtifactStore) http.Handler`.

- [ ] **Step 1:** Write `handler_test.go.jinja` (httptest: same cases as Python's `test_web.py`).
- [ ] **Step 2:** Add `ssr_checks go …`; run `bash tests/render-all.sh go`. Expected: ssr checks FAIL (no web adapter).
- [ ] **Step 3:** Implement. CSRF with `crypto/rand`, `crypto/subtle.ConstantTimeCompare`; also wrap with `http.NewCrossOriginProtection()` (Go ≥ 1.25).
- [ ] **Step 4:** `bash tests/render-all.sh go`. Expected: `ALL PASSED`.
- [ ] **Step 5:** Commit `feat(go): server-rendered UI (frontend=ssr)`.

### Task 3: Rust UI

**Files:**
- Create: `template/{% if stack == 'rust' %}crates{% endif %}/adapters/src/{% if frontend == 'ssr' %}web.rs{% endif %}.jinja`, `crates/adapters/templates/index.html`, `crates/adapters/static/app.css` (served with `include_str!`)
- Modify: `crates/adapters/Cargo.toml.jinja` (askama, askama_web with axum feature, `rand` or `getrandom`, `subtle`; versions pinned), `crates/adapters/src/lib.rs.jinja`, `crates/bootstrap/src/main.rs.jinja` + `Cargo.toml.jinja` (server under `serve_http`), `deny.toml` if a new license appears
- Modify: `tests/render-all.sh` (`ssr_checks rust …`; arch seed: add `axum` to `crates/application/Cargo.toml` and expect `bash ci/check-layers.sh` to fail)

**Interfaces:**
- Consumes: Task 1's plumbing; `cmd.serve` = `cargo run -q -p bootstrap`.
- Produces: `pub fn web_router(store: Arc<dyn ArtifactStore>) -> axum::Router` (match the existing http.rs store type).

- [ ] **Step 1:** Write `#[cfg(test)]` tests in `web.rs` with `tower::ServiceExt::oneshot`: same cases as Python.
- [ ] **Step 2:** Add `ssr_checks rust …`; run `bash tests/render-all.sh rust`. Expected: ssr checks FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `bash tests/render-all.sh rust`. Expected: `ALL PASSED` (cargo-deny included).
- [ ] **Step 5:** Commit `feat(rust): server-rendered UI (frontend=ssr)`.

### Task 4: .NET UI

**Files:**
- Create: `template/{% if stack == 'dotnet' %}src{% endif %}/{{ dotnet_name }}.Adapters/{% if frontend == 'ssr' %}Web{% endif %}/` (Razor Pages `Pages/Index.cshtml` + `Index.cshtml.cs`, `_ViewImports.cshtml`, `wwwroot/app.css`, a `WebUi` extension `AddWebUi()/MapWebUi()`), tests `tests/{{ dotnet_name }}.Tests/{% if frontend == 'ssr' %}WebUiTests.cs{% endif %}.jinja` (WebApplicationFactory or TestServer: same cases, antiforgery: POST without token → 400 is the framework default — assert 400 and record a ruling if the shared 403 cannot be met without custom code)
- Modify: `Adapters.csproj.jinja` (Razor SDK / `FrameworkReference Microsoft.AspNetCore.App` under `serve_http`), `Bootstrap/Program.cs.jinja`, `HttpHost.cs` guard → `serve_http`, `Bootstrap.csproj.jinja`, `Directory.Packages.props.jinja`, architecture tests (Domain/Application must not reference `Microsoft.AspNetCore.*`), Dockerfile `aspnet` image under `serve_http`
- Modify: `tests/render-all.sh` (`ssr_checks dotnet …`)

**Interfaces:**
- Consumes: Task 1's plumbing; `cmd.serve` = `dotnet run --project src/{{ dotnet_name }}.Bootstrap`.
- Produces: `IServiceCollection AddWebUi(this IServiceCollection)`, `WebApplication MapWebUi(this WebApplication)`.

- [ ] **Step 1:** Write `WebUiTests.cs.jinja` (`[Trait("Category", "E2E")]` not used: these are in-process and run in `verify`).
- [ ] **Step 2:** Add `ssr_checks dotnet …`; run `bash tests/render-all.sh dotnet`. Expected: ssr checks FAIL.
- [ ] **Step 3:** Implement. The shared spec's 403 cases: configure antiforgery failure to return 403 (an `IAlwaysRunResultFilter` that maps `IAntiforgeryValidationFailedResult` to 403) — if the framework only gives 400, change the shared spec to accept `[400, 403]` and ledger the ruling.
- [ ] **Step 4:** `bash tests/render-all.sh dotnet`. Expected: `ALL PASSED`.
- [ ] **Step 5:** Commit `feat(dotnet): server-rendered UI (frontend=ssr)`.

### Task 5: Docs, README, roadmap, full run

**Files:**
- Modify: `README.md` (Frontend row: per-stack engine; `ssr` option), `template/docs/roadmap.md.jinja` (tick UI for other stacks if listed), `CLAUDE.md` (Node needed for UI renders of every stack), `skills/project-starter/SKILL.md` (mention `frontend=ssr` if it lists answers)

- [ ] **Step 1:** Update docs.
- [ ] **Step 2:** `git diff --check`, `claude plugin validate .`. Expected: clean.
- [ ] **Step 3:** Commit `docs: frontend=ssr for Python, .NET, Go and Rust`.
- [ ] **Step 4:** Push and open the PR; CI runs all five stacks. Expected: 6 checks green.
