# Handoff — ProjectStarter (2026-11-25)

## สถานะตอนนี้

- `main` = `ff8ac78`, ตรงกับ `origin/main`, working tree สะอาด ไม่มี PR หรือ issue ที่เปิดค้าง
- CI `render-all` บน `main` ผ่านทั้งหมด (run ล่าสุด 2026-11-24, ทุก stack × shard)
- Roadmap (`template/docs/roadmap.md.jinja`) ระยะ 0–6: ส่วนที่ template ติดตั้งให้ได้ทำครบแล้ว ที่เหลือเป็นงานของทีมที่ใช้ project ที่ render ออกไป (ตัวชี้วัด, branch protection, correction record)

## สิ่งที่ทำไปแล้ว (เรียงตามเวลา, PR #29–#40)

| PR | เรื่อง | Spec / plan |
|---|---|---|
| #29–#31 | SSR frontend สำหรับ Python/.NET/Go/Rust, Data Protection keys (.NET), Post/Redirect/Get | `docs/superpowers/specs/2026-11-18-ssr-frontend-design.md` |
| #32 | roadmap: ติ๊กของระยะ 4 ที่ template ติดตั้งแล้ว | — |
| #33 | CI แยกแต่ละ stack เป็น shard `core` / `datastores` / `ui` | `docs/superpowers/specs/2026-11-18-repo-ci-design.md` |
| #34 | model check (TLA+/TLC) แบบ opt-in และ automerge tier 0 | — |
| #35 | ระยะ 6: worktree ต่องาน (`scripts/new-task.sh`, `scripts/end-task.sh`) | `docs/superpowers/specs/2026-11-20-parallel-worktrees-design.md` |
| #36 | ระยะ 6: release routine (`release-check.yml`, release agent แบบ opt-in) | `docs/superpowers/specs/2026-11-21-release-routine-design.md` |
| #37 | tests: `expect_fail` แสดง output เมื่อ check ผ่านทั้งที่ควร fail | — |
| #38, #39 | minor ที่ค้างจาก review ระยะ 6 (lock ของ new-task ด้วย noclobber file, publish รันซ้ำได้) | — |
| #40 | DAST: ZAP passive scan ใช้ thread เดียว กัน race ที่ทำให้ header หายแล้วไม่ fail | — |

Mutation testing: `docs/superpowers/specs/2026-11-18-mutation-testing-design.md`

## เรื่องที่ควรรู้ก่อนทำต่อ

- กฎการแก้ template อยู่ใน `CLAUDE.md`: แก้ `template/` หรือ `copier.yml` แล้วต้องรัน `bash tests/render-all.sh <stack>`; `AGENTS.md` ที่ render ต้อง < 60 บรรทัด; shell script ต้องรันใน Git Bash บน Windows ได้โดยไม่ใช้ `jq`
- `copier.yml` (`cmd`, `stk`) เป็นแหล่งความจริงเดียวของคำสั่งและ path ต่อ stack — อย่า hard-code ใน template
- Mutation testing ไม่รันบน Windows native (mutmut ต้องใช้ fork, gremlins/Stryker.NET มีปัญหา) — CI Linux เป็นตัวตัดสิน
- `new-task.sh` ใช้ lock แบบ noclobber file (`.git/new-task.lock`) เพราะ `mkdir` ไม่ exclusive พอบน CI (ดู commit `1fbf76c`, `497d79c`)
- ZAP scan ต้องใช้ passive-scan thread เดียว (PR #40) ถ้าเปลี่ยนกลับจะ flaky
- TypeScript ถูก pin ไว้ที่ `~6.0` จนกว่า typescript-eslint จะรองรับ 7.x
- CI ไม่มี Windows runner และไม่รัน `claude plugin validate .` — ต้องเช็คเองในเครื่อง

## งานที่อาจทำต่อ (ยังไม่มีใครเริ่ม)

- ขยาย mutation scope จาก domain ไป application (ตอนนี้เป็น non-goal เพราะช้าและต้องใช้ container)
- เพิ่ม `claude plugin validate .` ใน CI ถ้าติดตั้ง Claude Code CLI บน runner ได้
- เช็ค typescript-eslint ว่ารองรับ TypeScript 7 แล้วหรือยัง แล้วปลด pin `~6.0`
- `skills/project-starter/SKILL.md` บรรทัด ~101 ยังชี้ "next phase" เป็นระยะ 3 — ทบทวนว่ายังถูกไหม

## Housekeeping

- worktree `.claude/worktrees/priceless-ritchie-24e9db` (detached ที่ `a87f1bc`) และ local branch `claude/priceless-ritchie-24e9db`, `fix/zap-pscan-race` merge เข้า `main` แล้ว ลบได้

## คำสั่งที่ใช้บ่อย

```bash
uvx copier copy --trust --defaults -d project_name=demo -d stack=python . /tmp/demo   # render หนึ่ง project
bash tests/render-all.sh python                                                       # ทดสอบหนึ่ง stack
SHARD=core bash tests/render-all.sh python                                            # เฉพาะส่วน core
claude plugin validate .                                                              # เช็ค plugin manifest
git diff --check                                                                      # whitespace
```
