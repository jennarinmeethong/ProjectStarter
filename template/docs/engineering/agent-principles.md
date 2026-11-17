# Agent Engineering Principles

หลักการที่ repo นี้ใช้ทำงานร่วมกับ AI coding agents ที่มาและหลักฐานอยู่ในเอกสาร ProjectStarter (`docs/combined.md` ส่วนที่ 1 หัวข้อ 6.1)

1. **บทเรียนอยู่ในโครงสร้าง ไม่ใช่ในข้อความเตือน**
   ทุกครั้งที่ต้องแก้ agent ซ้ำ ให้ถามตามลำดับ:
   (a) ทำให้เขียนผิดไม่ได้ด้วย type/API/architecture ได้ไหม
   (b) ถ้าไม่ได้ เขียนเป็น lint/architecture check ได้ไหม
   (c) ถ้าไม่ได้ เป็น test/verification ได้ไหม
   (d) ถ้าไม่ได้ทั้งหมด จึงเขียนเป็นข้อความหนึ่งบรรทัดใน `AGENTS.md` พร้อมลิงก์เหตุผล
   ดูตารางตัดสินใน [where-rules-live.md](where-rules-live.md)
2. **อะไรที่ต้องใช้ความละเอียดอ่อนจึงจะใช้ได้ดี ให้ซ่อนไว้หลัง API ที่ปลอดภัย**
   API อันตราย (timer, raw SQL, effect, IPC) มีอยู่ในจุดเดียวที่ออกแบบมาให้ใช้ และถูกห้ามที่อื่นด้วย lint
3. **Codebase คือสิ่งที่ agent เลียนแบบ**
   ห้ามโค้ดใหม่พึ่งพา pattern เก่าด้วย check ก่อน แล้วค่อยเก็บกวาด
4. **แก้ที่ต้นเหตุ** — error message ของ check ต้องบอกว่าต้องทำอะไรแทน และชี้ไปยัง ADR
5. **Guardrail ต้องปกป้องตัวเอง** — config ของ check, acceptance test และไฟล์คำสั่งมี owner (เช่น CODEOWNERS)
   การเพิ่มทางหนี (disable, cast, skip) ถูกนับโดย `ci/guardrail-ratchet.sh` และห้ามเพิ่ม
6. **"เสร็จ" แปลว่ามีหลักฐาน** — คำสั่งที่รันพร้อม output, trace, seed หรือ screenshot
   "test ผ่านแล้ว" โดยไม่มีหลักฐานไม่นับ
7. **verification ทุกแบบมีขอบเขต** — ระบุเสมอว่าหลักฐานพิสูจน์อะไร และไม่ได้พิสูจน์อะไร
8. **ไว้ใจก่อน แล้วค่อยขนาน** — ห้าม automate หรือเพิ่มจำนวน agent จนกว่า inner loop จะวัดได้ว่าเชื่อถือได้ ([roadmap](../roadmap.md))
9. **วัดเสถียรภาพคู่กับปริมาณงาน** — จำนวน PR เป็นกิจกรรม ไม่ใช่ผลลัพธ์ วัด change failure rate และ revert rate ควบคู่เสมอ

## Anti-patterns ที่ต้องหลีกเลี่ยง

| Anti-pattern | ทางแก้ |
|---|---|
| เพิ่มคำเตือนใน `AGENTS.md` ทุกครั้งที่ agent พลาด | วงจร correction record ([agent-corrections](../agent-corrections/CR-template.md)) |
| เน้นด้วยตัวพิมพ์ใหญ่หรือ IMPORTANT | ย้ายเป็น check หรือ hook |
| ให้ agent สร้าง `AGENTS.md` เอง | มนุษย์เขียน เฉพาะสิ่งที่ไม่มีใน README |
| ใช้ timer / sleep / retry ปะอาการ | API ที่ถูกต้อง + lint ที่ชี้ต้นเหตุ |
| comment ที่ให้เหตุผลกับ workaround | เสนอแก้ rule ผ่าน PR ที่ owner อนุมัติ |
| เปิดให้ agent แก้ test และ config ของ check | protected path + CODEOWNERS + ratchet |
| ใช้ coverage เป็นเป้าหมาย | mutation testing, property-based test |
| model ใน property test ที่ลอก implementation | model ที่ง่ายกว่าและเป็นอิสระ |
| ใช้ AI reviewer หรือ prompt hook เป็น gate หลัก | command hook + CI; AI review เป็นชั้นเสริม |
| automate หรือขนานก่อน inner loop เชื่อถือได้ | ทำตาม [roadmap](../roadmap.md) ทีละระยะ |
| ใช้จำนวน PR เป็นตัววัด | วัดเสถียรภาพคู่ปริมาณงาน |
