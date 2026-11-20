# ProjectStarter

ชุดเริ่มโปรเจคใหม่ที่ "พร้อมทำงานกับ AI coding agent" ไม่ผูกกับ techstack: เลือกภาษาตอนสร้าง แล้วได้ `AGENTS.md`, guardrail ที่บังคับด้วยเครื่องมือ (type, lint, architecture check, CI ratchet, CODEOWNERS แบบ optional), risk tiers, roadmap และเอกสารประกอบ ใช้ได้ทั้ง **Claude Code** และ **Codex**

แนวคิดและหลักฐานทั้งหมดมาจาก [docs/combined.md](docs/combined.md) (ภาษาไทย): คู่มือ AI Agent Engineering, รายงานวิจัย guardrails, บันทึกวิจัย และ AGENTS.md template (ส่วนที่ 7)

## โครงสร้าง

| ชั้น | ที่อยู่ | เนื้อหา |
|---|---|---|
| Core (ไม่ผูกภาษา) | `template/docs/`, `template/AGENTS.md.jinja`, `template/SPEC.template.md` | หลักการ, ตาราง "กฎควรอยู่ที่ไหน", risk tiers, roadmap, ADR, correction record, feature map |
| Stack packs | ไฟล์ใน `template/` ที่ชื่อขึ้นต้นด้วย `{% if stack == '...' %}` + ค่า `cmd`/`stk` ใน `copier.yml` | TypeScript, Python, C#/.NET, Go, Rust |
| Agent adapters | `template/{% if 'claude' in agent_tools %}.claude{% endif %}/`, `CLAUDE.md` | Claude Code: deny rules + hooks; Codex ใช้ `AGENTS.md` ร่วมกัน + CI |
| Generator | `copier.yml` | คำถามและค่าคำนวณ (Copier) |
| Skill / plugin | `skills/project-starter/SKILL.md`, `.claude-plugin/` | skill เดียวใช้ได้ทั้ง Claude Code และ Codex |
| Tests | `tests/render-all.sh` | render ทุกชุด stack × agent แล้ว verify และใส่การละเมิดเพื่อตรวจว่า guardrail จับได้ |

### เครื่องมือต่อ stack

| แนวคิด | TypeScript | Python | C#/.NET | Go | Rust |
|---|---|---|---|---|---|
| Type เข้มงวด | `tsconfig` strict + `noUncheckedIndexedAccess` + `exactOptionalPropertyTypes` | pyright strict, ปิด `# type: ignore` | Nullable + TreatWarningsAsErrors + `latest-recommended` analyzers | Go compiler + `go vet` | Rust compiler, `unsafe_code = "forbid"` |
| Lint + ห้ามทางหนี | typescript-eslint `strictTypeChecked`, `ban-ts-comment` | ruff (PGH, ANN, TID banned APIs) | .NET analyzers, `.editorconfig` | golangci-lint v2 (`go tool`), `nolintlint` ต้องระบุ linter และเหตุผล | clippy pedantic + `-D warnings`, ทางหนีต้องเป็น `#[expect(..., reason)]` |
| Architecture | dependency-cruiser | import-linter (layers) | project references + NetArchTest | depguard (layers, drivers, web) + `internal/` | crate ต่อ layer + `ci/check-layers.sh` |
| Design rules (SOLID, ADR 0002) | cognitive complexity + SonarJS rules ที่คัดแล้ว (`eslint-plugin-sonarjs`), size limits, exhaustive `switch`, ห้าม clock/random/env/I/O ใน domain+application, domain ไม่มี dependency | ruff (C90, PL, FBT, ARG, SLF, TRY, S, banned APIs), pyright `reportImplicitOverride` | code-metrics analyzers, BannedApiAnalyzers, naming rules, NetArchTest (sealed, ไม่มี I/O) | gocognit, funlen, nestif, revive (argument-limit, flag-parameter), interfacebloat, ireturn, gochecksumtype, forbidigo | clippy thresholds (`clippy.toml`), `wildcard_enum_match_arm`, `disallowed_methods/types` ต่อ layer, `unwrap/expect/panic` ห้ามนอก test |
| Property test | fast-check | hypothesis | FsCheck | rapid (+ `rapid.MakeFuzz` for `go test -fuzz`) | proptest |
| Mutation test (domain) | Stryker (`stryker.config.json`) | mutmut + `ci/mutation-gate.py` | Stryker.NET (`tests/<Name>.Domain.Tests/stryker-config.json`) | gremlins (`.gremlins.yaml`) | cargo-mutants |
| Container (`containerize`) | Dockerfile multi-stage บน `node:24-slim`, non-root, `compose.yaml` แบบ read-only | Dockerfile multi-stage + uv บน `python:3.13-slim`, non-root | publish ลง `dotnet/runtime:10.0`, `$APP_UID` | static binary บน `distroless/static:nonroot`, UID 65532 | release binary บน `distroless/cc:nonroot`, UID 65532 |
| Datastores (`datastores`: postgres, mysql/mariadb, sqlserver, oracle, mongodb, dynamodb, cosmosdb, s3, redis) | `pg`, `mysql2`, `mssql`, `oracledb`, `mongodb`, `@aws-sdk/client-dynamodb`, `@azure/cosmos`, `@aws-sdk/client-s3`, `redis` + `@testcontainers/*`, dependency-cruiser แยก driver ไว้ใน adapters, ESLint ห้ามประกอบ SQL จาก string และห้าม `$where` | `psycopg`, `PyMySQL`, `mssql-python`, `oracledb`, `pymongo`, `boto3` (DynamoDB, S3), `azure-cosmos`, `redis` + `testcontainers`, import-linter `forbidden`, ruff `S608` | `Npgsql`, `MySqlConnector`, `Microsoft.Data.SqlClient`, `Oracle.ManagedDataAccess.Core`, `MongoDB.Driver`, `AWSSDK.DynamoDBv2`, `Microsoft.Azure.Cosmos`, `AWSSDK.S3`, `StackExchange.Redis` + `Testcontainers.*`, `CA2100` | `pgx`, `go-sql-driver/mysql`, `go-mssqldb`, `go-ora`, `mongo-driver/v2`, `aws-sdk-go-v2` (DynamoDB, S3), `azcosmos`, `go-redis` + `testcontainers-go`, depguard, ruleguard (SQL จาก string, `$where`) | `sqlx` 0.9 (postgres, mysql; `SqlSafeStr`: SQL จาก string compile ไม่ผ่าน), `tiberius`, `oracle-rs` (clippy `disallowed_methods` บังคับผ่าน gateway `&'static str`), `mongodb`, `aws-sdk-dynamodb`, `azure_data_cosmos` (beta), `aws-sdk-s3`, `redis` + `testcontainers-modules` |
| HTTP API (`http_api`) | Hono, Playwright API tests, ZAP baseline | FastAPI + uvicorn, Playwright (Python), ZAP baseline | ASP.NET Core minimal API, Microsoft.Playwright, ZAP baseline | `net/http` (ServeMux), playwright-go, ZAP baseline | axum, Playwright (TypeScript ใน `e2e/`), ZAP baseline |
| Frontend (`frontend`) | React (Vite): `@eslint-react`, `react-hooks`, `jsx-a11y-x` strict, Testing Library · Vue (Vite): `eslint-plugin-vue`, `vuejs-accessibility`, `vue-tsc`, Vue Test Utils · Next.js: `@next/eslint-plugin-next`, nonce CSP ใน `src/proxy.ts`, standalone server · Angular: angular-eslint (template accessibility), `strictTemplates`, zoneless, `ng test` บน Vitest · React Native (Expo): react-native-web สำหรับ test และ web build, กฎ a11y บน touchable/Image · ทุกตัว: Playwright + axe, ZAP | `frontend=ssr`: FastAPI + Jinja2 (server-rendered), Playwright + axe ใน `e2e-ui/` | `frontend=ssr`: ASP.NET Core Razor Pages, Playwright + axe ใน `e2e-ui/` | `frontend=ssr`: `net/http` + `html/template`, Playwright + axe ใน `e2e-ui/` | `frontend=ssr`: axum + askama, Playwright + axe ใน `e2e-ui/` |
| Security (OWASP) | dependency audit, gitleaks, hadolint + `ci/check-dockerfile.sh`, Dependabot, checklist tier 2–3 ใน `docs/security/owasp.md` | เหมือนกัน | เหมือนกัน | เหมือนกัน + `govulncheck` (เฉพาะโค้ดที่ถูกเรียก), `gosec` | เหมือนกัน + `cargo deny` (advisories, licenses, sources) |
| Test runner | vitest | pytest | xUnit v3 (Microsoft.Testing.Platform) | `go test` | `cargo test` |

## ความต้องการ

- `git`, `bash` (Git Bash บน Windows), [uv](https://docs.astral.sh/uv/) ≥ 0.8 (Copier ≥ 9.4 รันผ่าน `uvx`)
- TypeScript: Node.js ≥ 22.12 + npm · Python: uv (ดึง Python 3.13 ให้เอง) · .NET: .NET SDK 10 · Go: Go ≥ 1.26 (golangci-lint และ govulncheck ถูก pin ใน `go.mod` และรันด้วย `go tool`) · Rust: rustup (`rust-toolchain.toml` pin 1.99) + `cargo install cargo-deny`; `http_api` ต้องมี Node.js สำหรับ Playwright ใน `e2e/` และ `frontend=ssr` ต้องมี Node.js สำหรับ Playwright + axe ใน `e2e-ui/` (ทุก stack)
- `tests/render-all.sh` ต้องมี Docker ที่รันอยู่ (hadolint, gitleaks และ build image ของแต่ละ stack) · โปรเจคที่สร้างด้วย `containerize=false` ไม่ต้องมี Docker ในเครื่อง (CI ใช้ Docker ของ GitHub runner สำหรับ gitleaks)

## ใช้งาน

สร้างโปรเจคใหม่ (ถามคำถามแบบ interactive):

```bash
uvx copier copy --trust <path-to-ProjectStarter> ../my-app
```

หรือกำหนดค่าทั้งหมดในคำสั่งเดียว:

```bash
uvx copier copy --trust --defaults -d project_name=my-app -d stack=python -d 'agent_tools=["claude","codex"]' <path-to-ProjectStarter> ../my-app
```

คำถามที่ปิดไว้เป็นค่าเริ่มต้น (เปิดด้วย `-d <ชื่อ>=true` หรือ `copier update`):

- `model_check`: TLA+ model ของคิว export (lease ที่หมดอายุ, การ complete ที่ต้องเป็นเจ้าของงาน) ตรวจด้วย TLC ใน Docker ผ่าน `bash ci/model-check.sh` และ CI job `model-check` (ADR 0006) เหมาะกับโปรเจคที่มี protocol แบบ concurrent
- `automerge`: workflow ที่เปิด GitHub auto-merge ให้ PR ที่แก้แต่เอกสาร (risk tier 0 ตาม `ci/risk-tier.sh`) และปิดให้ PR อื่นทั้งหมด ต้องเปิด "Allow auto-merge" และ branch protection ที่มี required status checks ก่อน ไม่อย่างนั้น GitHub จะ merge ทันที

`.github/CODEOWNERS` สร้างเฉพาะเมื่อระบุ `guardrail_owner` (เช่น `-d guardrail_owner=@my-org/platform`) ถ้าไม่ระบุจะไม่มีไฟล์นี้ และเพิ่มภายหลังได้ด้วย `copier update`

ดึงการปรับปรุง template เข้าโปรเจคที่สร้างไปแล้ว (รันในโฟลเดอร์โปรเจค):

```bash
uvx copier update --trust
```

### ใช้ผ่าน skill (Claude Code และ Codex)

ติดตั้ง skill ระดับผู้ใช้ (`~/.claude/skills/` และ `~/.agents/skills/`) แล้วสั่ง agent ว่า "สร้างโปรเจคใหม่" ได้จากทุกโฟลเดอร์:

```bash
bash scripts/install-skill.sh
```

หรือติดตั้งเป็น Claude Code plugin จาก repo นี้:

```bash
claude plugin marketplace add <path-to-ProjectStarter>
```

```bash
claude plugin install project-starter@project-starter-marketplace
```

## ทดสอบ template

render ทุกชุดและตรวจทั้งกรณีผ่านและกรณีที่ต้องถูกปฏิเสธ (ใช้เวลาหลายนาทีเพราะติดตั้ง dependency จริง):

```bash
bash tests/render-all.sh
```

ทดสอบ stack เดียว:

```bash
bash tests/render-all.sh python
```

ทดสอบเฉพาะส่วนของ stack ด้วย `SHARD=core`, `SHARD=datastores` หรือ `SHARD=ui` (ค่าเริ่มต้น `all` รันทุกส่วน):

```bash
SHARD=ui bash tests/render-all.sh python
```

CI (`.github/workflows/render-all.yml`) รัน `tests/render-all.sh` ทุก stack และทุกส่วนขนานกัน (15 job) ในทุก PR เข้า `main` จึงไม่จำเป็นต้องรันครบทุก stack ในเครื่อง ระหว่างพัฒนาให้รันเฉพาะ stack ที่แก้

## เพิ่ม stack ใหม่

1. เพิ่ม choice ใน `stack` และเพิ่มสาขาใน `cmd` กับ `stk` ของ `copier.yml` (คำสั่ง, ไฟล์ guardrail, รูปแบบทางหนีสำหรับ ratchet, path ของแต่ละ layer)
2. เพิ่มไฟล์ใน `template/` โดยตั้งชื่อแบบมีเงื่อนไข เช่น `{% if stack == 'go' %}go.mod{% endif %}.jinja` และวางตัวอย่าง domain → application → adapters → bootstrap
3. เพิ่ม setup ของ stack ใน `template/.github/workflows/ci.yml.jinja` และสาขาตรวจ strictness ใน `template/ci/guardrail-ratchet.sh.jinja`
4. เพิ่มกรณีใน `tests/render-all.sh` (verify ผ่าน + การละเมิดที่ต้องถูกจับ) แล้วรันจนผ่าน

## License

MIT (ดู [LICENSE](LICENSE)) โปรเจคที่สร้างจาก template ไม่ได้รับ license นี้ติดไป เลือก license ของตัวเองได้
