# ProjectStarter

ชุดเริ่มโปรเจคใหม่ที่ "พร้อมทำงานกับ AI coding agent" ไม่ผูกกับ techstack: เลือกภาษาตอนสร้าง แล้วได้ `AGENTS.md`, guardrail ที่บังคับด้วยเครื่องมือ (type, lint, architecture check, CI ratchet, CODEOWNERS แบบ optional), risk tiers, roadmap และเอกสารประกอบ ใช้ได้ทั้ง **Claude Code** และ **Codex**

แนวคิดและหลักฐานทั้งหมดมาจาก [docs/combined.md](docs/combined.md) (ภาษาไทย): คู่มือ AI Agent Engineering, รายงานวิจัย guardrails, บันทึกวิจัย และ AGENTS.md template (ส่วนที่ 7)

## โครงสร้าง

| ชั้น | ที่อยู่ | เนื้อหา |
|---|---|---|
| Core (ไม่ผูกภาษา) | `template/docs/`, `template/AGENTS.md.jinja`, `template/SPEC.template.md` | หลักการ, ตาราง "กฎควรอยู่ที่ไหน", risk tiers, roadmap, ADR, correction record, feature map |
| Stack packs | ไฟล์ใน `template/` ที่ชื่อขึ้นต้นด้วย `{% if stack == '...' %}` + ค่า `cmd`/`stk` ใน `copier.yml` | TypeScript, Python, C#/.NET |
| Agent adapters | `template/{% if 'claude' in agent_tools %}.claude{% endif %}/`, `CLAUDE.md` | Claude Code: deny rules + hooks; Codex ใช้ `AGENTS.md` ร่วมกัน + CI |
| Generator | `copier.yml` | คำถามและค่าคำนวณ (Copier) |
| Skill / plugin | `skills/project-starter/SKILL.md`, `.claude-plugin/` | skill เดียวใช้ได้ทั้ง Claude Code และ Codex |
| Tests | `tests/render-all.sh` | render ทุกชุด stack × agent แล้ว verify และใส่การละเมิดเพื่อตรวจว่า guardrail จับได้ |

### เครื่องมือต่อ stack

| แนวคิด | TypeScript | Python | C#/.NET |
|---|---|---|---|
| Type เข้มงวด | `tsconfig` strict + `noUncheckedIndexedAccess` + `exactOptionalPropertyTypes` | pyright strict, ปิด `# type: ignore` | Nullable + TreatWarningsAsErrors + `latest-recommended` analyzers |
| Lint + ห้ามทางหนี | typescript-eslint `strictTypeChecked`, `ban-ts-comment` | ruff (PGH, ANN, TID banned APIs) | .NET analyzers, `.editorconfig` |
| Architecture | dependency-cruiser | import-linter (layers) | project references + NetArchTest |
| Design rules (SOLID, ADR 0002) | cognitive complexity + SonarJS rules ที่คัดแล้ว (`eslint-plugin-sonarjs`), size limits, exhaustive `switch`, ห้าม clock/random/env/I/O ใน domain+application, domain ไม่มี dependency | ruff (C90, PL, FBT, ARG, SLF, TRY, S, banned APIs), pyright `reportImplicitOverride` | code-metrics analyzers, BannedApiAnalyzers, naming rules, NetArchTest (sealed, ไม่มี I/O) |
| Property test | fast-check | hypothesis | FsCheck |
| Container (`containerize`) | Dockerfile multi-stage บน `node:24-slim`, non-root, `compose.yaml` แบบ read-only | Dockerfile multi-stage + uv บน `python:3.13-slim`, non-root | publish ลง `dotnet/runtime:10.0`, `$APP_UID` |
| Security (OWASP) | dependency audit, gitleaks, hadolint + `ci/check-dockerfile.sh`, Dependabot, checklist tier 2–3 ใน `docs/security/owasp.md` | เหมือนกัน | เหมือนกัน |
| Test runner | vitest | pytest | xUnit v3 (Microsoft.Testing.Platform) |

## ความต้องการ

- `git`, `bash` (Git Bash บน Windows), [uv](https://docs.astral.sh/uv/) ≥ 0.8 (Copier ≥ 9.4 รันผ่าน `uvx`)
- TypeScript: Node.js ≥ 22.12 + npm · Python: uv (ดึง Python 3.13 ให้เอง) · .NET: .NET SDK 10
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

## เพิ่ม stack ใหม่

1. เพิ่ม choice ใน `stack` และเพิ่มสาขาใน `cmd` กับ `stk` ของ `copier.yml` (คำสั่ง, ไฟล์ guardrail, รูปแบบทางหนีสำหรับ ratchet, path ของแต่ละ layer)
2. เพิ่มไฟล์ใน `template/` โดยตั้งชื่อแบบมีเงื่อนไข เช่น `{% if stack == 'go' %}go.mod{% endif %}.jinja` และวางตัวอย่าง domain → application → adapters → bootstrap
3. เพิ่ม setup ของ stack ใน `template/.github/workflows/ci.yml.jinja` และสาขาตรวจ strictness ใน `template/ci/guardrail-ratchet.sh.jinja`
4. เพิ่มกรณีใน `tests/render-all.sh` (verify ผ่าน + การละเมิดที่ต้องถูกจับ) แล้วรันจนผ่าน

## License

MIT (ดู [LICENSE](LICENSE)) โปรเจคที่สร้างจาก template ไม่ได้รับ license นี้ติดไป เลือก license ของตัวเองได้
