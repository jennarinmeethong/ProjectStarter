# CR-XXXX: <สิ่งที่ agent ทำผิดซ้ำ ในหนึ่งบรรทัด>

คัดลอกไฟล์นี้เป็น `CR-0001-<slug>.md` ทุกครั้งที่ต้องแก้ agent เรื่องเดิมซ้ำ (ที่มา: `docs/combined.md` ส่วนที่ 1 หัวข้อ 6.6)

- **พบที่:** <PR / review / CI fail / incident> (เกิดซ้ำ <n> ครั้งใน <ช่วงเวลา>)
- **หมวด:** <เช่น แก้อาการแทนต้นเหตุ / API อันตราย / ข้าม layer>
- **ชั้นที่เลือก** (ต่ำสุดที่ encode ได้: type/API > lint > architecture > hook > test > verification > prose):
  1. <ชั้นหลัก และสิ่งที่เปลี่ยน>
  2. <ชั้นเสริม>
- **ข้อความ error:** บอกว่าต้องทำอะไรแทน และชี้ไปที่ `docs/adr/<NNNN>-<slug>.md`
- **Test ของ rule:** <n> invalid จาก PR จริง, <n> valid
- **สถานะ:** warn (จุดเดิม <n> จุด) → error เมื่อ burn-down = 0 (เป้า: <วันที่>)
- **สิ่งที่ลบออก:** <บรรทัดใน AGENTS.md ที่ไม่จำเป็นแล้ว>
- **ตัวชี้วัด:** จำนวนครั้งที่ rule ทำงานต่อสัปดาห์, จำนวน override, false positive
