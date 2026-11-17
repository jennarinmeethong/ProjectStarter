# ข้อกำหนดแต่ละประเภทควรอยู่ที่ใด

ใช้ตารางนี้ทุกครั้งที่กำลังจะเพิ่มบรรทัดใน `AGENTS.md` ถ้าข้อกำหนดอยู่ในแถวที่ "ที่หลัก" ไม่ใช่ agent instructions ให้ encode ที่ชั้นนั้นแทน (ที่มา: `docs/combined.md` ส่วนที่ 1 หัวข้อ 6.8)

| ประเภทข้อกำหนด | ตัวอย่าง | ที่หลัก | ที่เสริม | ไม่ควรอยู่ที่ |
|---|---|---|---|---|
| สถานะที่ต้องไม่เกิดขึ้น | "paid ต้องมี paidAt" | **Code/API design** (union / sealed type) | test | AGENTS.md |
| การสับสน ID หรือหน่วย | UserId กับ OrderId, เงินเป็น float | **Code/API design** (branded / value type) | lint | AGENTS.md |
| API อันตรายที่ต้องใช้ความละเอียดอ่อน | timer, raw SQL, effect | **Code/API design** (framework primitive) | **Lint** ห้ามนอกจุดที่อนุญาต | AGENTS.md อย่างเดียว |
| ขอบเขตระหว่าง layer หรือ process | domain ห้าม import adapters | **Architecture check** | lint | code review |
| Driver ของ database/cache | `pg`, `psycopg`, `Npgsql` นอก adapters | **Architecture check** (ADR 0003) | project references | code review |
| Migration ที่ merge แล้ว | แก้ไฟล์ใน `migrations/` | **CI** ratchet (append-only) | CODEOWNERS tier 3 | AGENTS.md อย่างเดียว |
| SQL injection | ต่อ string เข้า query | **Lint** (ESLint `no-restricted-syntax` / ruff `S608` / `CA2100` / ruleguard `sqlFromStrings`; Rust: type system ของ sqlx) | contract test กับ DB จริง | code review |
| ความเข้มของ type | strict mode | **Config** | **CI** (ratchet ตรวจว่าไม่ถูกลด) | AGENTS.md |
| ทางหนีจากกฎ | cast, ignore, disable | **Lint** | **CI** ratchet | AGENTS.md อย่างเดียว |
| Style และ formatting | การจัดรูปแบบ, import order | **Config** (formatter/linter) | CI | AGENTS.md |
| ไฟล์ที่ agent ห้ามแก้ | config ของ guardrail, acceptance test | **CI + CODEOWNERS** | harness deny/hook | AGENTS.md อย่างเดียว |
| Dependency ที่มีช่องโหว่ที่รู้แล้ว | package ที่มี CVE | **CI** (dependency audit ทุก PR + รายสัปดาห์; ข้อยกเว้นต้องมีเหตุผลและวันหมดอายุ เช่น `.audit-exceptions.json`) | Dependabot/Renovate | AGENTS.md อย่างเดียว |
| Secret ใน repo | API key, token, password | **CI** (gitleaks สแกน history ทุก PR) | rotate + ลบจาก history | AGENTS.md อย่างเดียว |
| ความปลอดภัยของ container | รันเป็น root, tag `latest`, ADD จาก URL | **Lint** (hadolint) + **CI** (`ci/check-dockerfile.sh`) | `compose.yaml` แบบ read-only | code review |
| ความปลอดภัยของ feature ใหม่ | สิทธิ์, input, secret ใน log | **Checklist** ใน `docs/security/owasp.md` สำหรับ PR tier 2–3 | DAST (ZAP) | ไม่ทำอะไร |
| ต้องรัน check ก่อนจบงาน | typecheck ก่อน "เสร็จ" | **CI** (required check) | Stop hook | AGENTS.md อย่างเดียว |
| ความถูกต้องของพฤติกรรม | ผลของการคำนวณ | **Tests** (example + property) | runtime verification | AGENTS.md |
| Protocol กระจายหรือ concurrency | notification ข้ามอุปกรณ์ | **Verification** (model check) + property test | runtime monitor | code review อย่างเดียว |
| พฤติกรรม UI | ปุ่ม, สถานะหน้าจอ | **Runtime verification** (Playwright) | artifact ใน PR | unit test อย่างเดียว |
| พฤติกรรมและ header ของ HTTP API | validation, problem details, CSP | **Runtime verification** (Playwright API tests) | **DAST** (OWASP ZAP baseline ใน CI) | code review อย่างเดียว |
| โค้ด legacy ที่ห้ามเลียนแบบ | `legacy/` | **Architecture check** (ห้าม import) | AGENTS.md (ชั่วคราว) | ไม่ทำอะไร |
| คำสั่งที่ใช้ตรวจงาน | คำสั่งรัน test ไฟล์เดียว | **Agent instructions** | README | ไม่ระบุเลย |
| เจตนาและการจัดการความขัดแย้ง | "test ขัดกับ spec ให้หยุดและถาม" | **Agent instructions** | protected acceptance test | — |
| คำศัพท์ของโดเมนและแผนที่ feature | feature ID, ชื่อหน้าจอ | **Docs** (feature map) ที่ agent instructions ชี้ไป | traceability ใน CI | หัวของ agent |
| ความชอบที่มีข้อยกเว้น | prefer named exports | **Agent instructions** หรือ AGENTS.md ในโฟลเดอร์ย่อย | — | hook |
| การเปลี่ยนแปลงที่เสี่ยงสูง | auth, payments, migration | **CI + CODEOWNERS + branch protection** | AGENTS.md (แจ้ง) | ดุลยพินิจรายครั้ง |
| เหตุผลของกฎ | ทำไมห้าม timer | **ADR** ที่ error message ลิงก์ไป | — | comment อิสระในโค้ด |
