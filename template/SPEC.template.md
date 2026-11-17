# SPEC: <feature ID> — <ชื่อ>

คัดลอกเป็น `docs/specs/<feature-id>.md` ก่อนเริ่มงาน tier 2–3 spec นี้คือ definition of done

- **Feature ID:** <จาก docs/feature-map.md>
- **Risk tier:** <0–3 ตาม docs/risk-tiers.md>
- **ผู้อนุมัติ:** <ชื่อ> (จำเป็นสำหรับ tier 2–3)

## ปัญหาและผู้ใช้
<ใครเจออะไร ทำไมต้องแก้ตอนนี้>

## Requirements
- **REQ-1:** <พฤติกรรมที่ตรวจได้>
- **REQ-2:** <...>

## Acceptance criteria (กลายเป็น test ใน tests/acceptance/)
- [ ] REQ-1: Given <...> When <...> Then <...>
- [ ] REQ-2: ...

## นอกขอบเขต
<สิ่งที่ไม่ทำในงานนี้>

## Assumptions และคำถามที่ยังเปิด
<สิ่งที่ตีความได้หลายแบบ และใครเป็นคนตัดสิน>

## หลักฐานที่ต้องแนบใน PR
- [ ] คำสั่ง verify ที่รันพร้อม output สุดท้าย
- [ ] test ที่ fail ก่อนแก้ และผ่านหลังแก้ (สำหรับ bug)
- [ ] trace / screenshot ของ feature ID (สำหรับ UI)
- [ ] seed / ลำดับที่ย่อแล้ว (สำหรับ property test ที่เคย fail)
