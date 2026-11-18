# Server-rendered UI for Python, .NET, Go and Rust (phase 5d)

## Why

`frontend` is asked only for TypeScript. A project on any other stack that needs a screen has no starting point, and
its first UI is written without the guardrails ADR 0005 gives TypeScript (UI as a driving adapter, accessibility as a
gate, strict CSP, ZAP). This phase closes that gap so every stack can start with a UI that is held to the same rules.

The user handed the how to me; every choice below is my call, with the reason.

## Goals / non-goals / anti-goals

- Goal: Python, .NET, Go and Rust can pick `frontend=ssr`: a server-rendered UI in the stack's own language, a driving
  adapter over the same `complete export` use case, same screen and behaviour as the TypeScript UIs.
- Goal: the same gates as ADR 0005: Playwright user flows + axe (WCAG 2.1 AA) on every PR (job `ui`), ZAP baseline from
  `/` when containerized, framework/template engine kept out of domain/application by the existing layer tools.
- Goal: `tests/render-all.sh` renders `frontend=ssr` per stack, runs its verify and UI tests, and proves seeded
  violations are rejected (template engine imported in application; missing CSP header fails ZAP; an inaccessible
  control fails axe).
- Non-goal: SPA or WebAssembly frontends for these stacks (Blazor WASM, Leptos, Go WASM).
- Non-goal: changing the TypeScript frontends.
- Anti-goal: a UI that "works" by relaxing a guardrail: no `'unsafe-inline'` in CSP, no new ZAP `IGNORE` lines, no
  storage access from the template/handler code.

## Approaches

| | What | Trade-off |
|---|---|---|
| **A (picked)** | Server-rendered HTML in each stack's language, plain HTML forms (POST → redirect/render) | One language per repo, works without JavaScript, trivially strict CSP; less interactive than an SPA |
| B | Reuse the TypeScript SPAs, calling the stack's HTTP API | Rich UI and reuses tested code; makes every repo bilingual (two toolchains, two lint/arch setups, CORS/auth between them) |
| C | WebAssembly UI (Blazor WASM, Leptos) | Same language in the browser; only some stacks have one, large toolchain and bundle, nothing for Python/Go |

Picked A: a starter should not force a second language on a Python/Go/.NET/Rust team, and server-rendered forms are the
smallest UI that still exercises every gate (accessibility, CSP, CSRF, layering).

## Design

### Question

`frontend` becomes asked for every stack. TypeScript keeps its choices. Other stacks get `None: none` and
`Server-rendered (<engine>): ssr`. Invalid combinations (e.g. `ssr` on TypeScript, `react` on Go) are rejected by a
validator.

### Per stack

| Stack | Server | Templates | CSRF |
|---|---|---|---|
| Python | FastAPI (existing HTTP adapter's server) | Jinja2 (autoescape on) | double-submit token (below) |
| .NET | ASP.NET Core | Razor Pages | built-in antiforgery (`__RequestVerificationToken`) |
| Go | `net/http` | `html/template` + `embed` | double-submit token |
| Rust | axum | askama (compile-time, autoescape) | double-submit token |

- The UI lives in the adapters layer (`adapters/web` or the stack's equivalent) and calls the same use case and
  `ArtifactStore` port as the HTTP API. Storage is server-side: the store the bootstrap already wires (in-memory by
  default, or the chosen datastore). No browser storage.
- Bootstrap starts the HTTP server when `http_api or frontend == 'ssr'`; when both are on, the JSON API and the UI share
  one server (API under its existing paths, UI at `/`).
- Screen: same as the TypeScript UI. Labels "Job id" and "Content", button "Complete export", a `role="status"` result
  "Saved as exports/<id>.csv", the same job-id rule and error text "Enter a job id (letters, digits, - or _) and some
  content.". Same contract means the browser spec can be shared.
- Styling: one static CSS file served from the app; no inline `style` or `script`.
- Security headers on every UI response: the same set as the HTTP API plus a page CSP
  (`default-src 'none'; style-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'`).
- CSRF (Python/Go/Rust): random token in a `__Host-csrf` cookie (`Secure`, `HttpOnly`, `SameSite=Strict`) and a hidden
  `csrf_token` field, compared in constant time on POST, plus a reject when `Sec-Fetch-Site` is present and not
  `same-origin`. The field name is one ZAP recognises, so rule 10202 passes without an `IGNORE`.

### Browser tests

One Node `e2e-ui/` folder per generated project (Playwright + `@axe-core/playwright`), the same spec as the TypeScript
`e2e-ui/app.spec.ts`, with `webServer` starting the stack's server. `cmd.test_ui` runs it; CI job `ui` installs Node
and Chromium. Reason: one spec proves identical behaviour across all five stacks, and `@axe-core/playwright` is the
maintained axe integration. Rust already uses a Node `e2e/` folder for API tests, so this is not a new kind of
dependency.

### Docs and guardrails

- ADR 0005 gains the `ssr` branch (composition root, CSRF, CSP, enforcement table per stack).
- Layer tools forbid the template engine and web framework in domain/application: import-linter (Python),
  architecture tests (.NET), depguard (Go), crate dependencies (Rust).
- `.zap/rules.tsv` is generated when `frontend != 'none'` for these stacks too; `guardrail_files` follow.
- AGENTS.md stays under 60 lines (it already has the generic UI line).
- README matrix: the Frontend row lists the per-stack engine.

### Tests in this repo

`frontend_checks` in `tests/render-all.sh` gets an `ssr` path per stack: render with `frontend=ssr` (and once with
`http_api=true` to cover the shared server), verify, `cmd.test_ui`, ZAP from `/` with a seeded missing CSP, a seeded
template-engine import in application rejected by the layer tool, and a seeded unlabeled input rejected by axe.

## Left to the builder

- Exact package versions (pin at implementation; check licenses: Jinja2 BSD, askama MIT/Apache-2.0,
  `@axe-core/playwright` MPL-2.0 is already used).
- File names inside each adapter, and how the validator message reads.
- Whether Razor Pages or Razor components (static SSR) fit the .NET project layout better; either meets the design if
  antiforgery and the layer rules hold.
