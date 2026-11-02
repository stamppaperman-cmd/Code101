# System Stats Widget — design spec (2026-07-17)

Widget กระจกเล็ก ๆ บน desktop แสดง **CPU + RAM รวมของเครื่อง** และ **รายชื่อแอปที่กินทรัพยากร เรียงจากมากไปน้อย** วางอยู่ *ใต้* กลุ่ม widget เดิม (ปฏิทิน + วงแหวนแบตเตอรี่) และใช้ภาษาภาพเดียวกัน: กระจกโปร่งแสง มุมโค้ง มีสีบอกระดับโหลดตอนเครื่องทำงานหนัก

## 1. Layout

```
┌──────────────────────────────┐
│  ▣ CPU 34%      ▣ RAM 12.4G  │  ← "ชิปเหลี่ยม" เสมือนจริง (มีขาชิป+die)
│    8 cores        /16 GB     │     progress = กรอบเหลี่ยมวิ่งรอบตัวชิป
│  🌡 62°C  ▓▓▓░░░░  ปกติ      │  ← อุณหภูมิ CPU + thermal state
│  ─────────────────────────── │
│  🀫 Xcode          ████ 41%  │  ← top 4 apps เรียง CPU มาก→น้อย
│  🌐 Chrome         ██   18%  │     (สลับโหมดดู RAM ได้ด้วยคลิกหัวคอลัมน์)
│  💬 Messages       ▌     6%  │
│  ⚙️ WindowServer   ▌     5%  │
│  อื่น ๆ อีก N แอป            │
└──────────────────────────────┘
```

- ขนาดเริ่มต้น **300 × 360 pt** (กว้างเท่ากลุ่ม widget สองอันบน) — ชิป 2 ตัวบน, แถบอุณหภูมิ 1 แถว, เส้นคั่นบาง, แถวแอป **4 แถว** + บรรทัดรวม "อื่น ๆ"
- **Chip gauge** (แทนวงแหวนเดิม): วาดชิปกึ่งเสมือนจริง — ตัว package สี่เหลี่ยมมุมโค้งสีเทาเข้ม, ขาชิปทองรอบตัว (CPU = ขา 4 ด้านแบบ QFP; RAM = ขาแถวเดียวด้านล่าง + ลาย die ชิปหน่วยความจำ 3 ก้อน ให้สองตัวหน้าตาต่างกัน), จุด pin-1 มุมซ้ายล่าง, ลายเส้น trace จาง ๆ บน package
  - **Progress = กรอบเหลี่ยม**วิ่งรอบขอบ package: SwiftUI `RoundedRectangle(cornerRadius: 10).trim(from: 0, to: fraction)` stroke `lineWidth 4, lineCap .round` ทับบน track `white.opacity(0.16)` — `.trim` บน RoundedRectangle เริ่มที่มุมบนซ้ายแล้ววิ่งตามเข็ม
  - ตัวเลข % (CPU) / GB (RAM) + คำว่า CPU/RAM คงอยู่กลางชิปเหมือนเดิม
- แถบอุณหภูมิ: ไอคอน thermometer + ค่า °C (เฉลี่ยเซ็นเซอร์ CPU die) + แถบ bar สเกล 30–100°C + ป้าย thermal state ("ปกติ / เริ่มร้อน / ร้อน / วิกฤต")
- แต่ละแถวแอป: app icon (จาก `NSRunningApplication.icon`), ชื่อ, แถบ bar แนวนอน + ตัวเลข %/GB
- คลิกหัววงแหวน CPU/RAM เพื่อสลับว่า list ด้านล่างเรียงตาม CPU หรือ RAM (default: CPU)

### ตรวจจับแอปค้าง (stuck-app detection) `[implemented]`

- เกณฑ์: แอป (เฉพาะ Dock app ที่ปิดได้) กิน CPU **≥90% ของ 1 core ต่อเนื่อง ≥30 วินาที** → ถือว่าค้าง; ปล่อยเมื่อ CPU ตกต่ำกว่า 70% (มี hysteresis กันกระพริบ)
- UI: แถวพื้นแดงจาง + ไอคอน ⚠️ + ปุ่ม ✕ แดงโชว์ค้างโดยไม่ต้อง hover; คลิกยืนยัน "ปิด?" แล้วจะ **`forceTerminate()` ตรง ๆ** (แอปค้างไม่ตอบ terminate ปกติ)
- แอปค้าง**ลอยขึ้นบนสุดของลิสต์เสมอ** ไม่ว่ากำลังเรียงตาม CPU หรือ RAM
- เพื่อให้จับได้แม้ widget ถูกหน้าต่างบัง: occlusion ไม่หยุดวัดแล้ว แต่**ลดจังหวะเป็น 10 วิ** (มองเห็น = 2 วิ) — ต้นทุนตอนถูกบัง ~ตอนไม่มี widget เพราะ snapshot ที่ค่าเท่าเดิมถูกข้ามไม่ render
- ทดสอบจริงด้วยแอปจุดไฟ CPU (BurnTest.app spin 99% 1 core): ขึ้นแดงหลัง ~40 วิ, หายเองเมื่อโปรเซสตาย

### แสดงเฉพาะ Dock apps `[implemented]`

- ลิสต์กรองเหลือ `activationPolicy == .regular` เท่านั้น — daemon (peopled ฯลฯ) และ agent ระบบ (Window Manager, Tips, Notification Center) ไม่แสดง แต่ยอดใช้งานยังรวมในชิป CPU/RAM ด้านบน

### ปิดแอปจากแถวรายชื่อ (quit-from-widget)

- Hover แถวแอป → พื้นแถวสว่างขึ้นเล็กน้อย + ตัวเลข % สลับเป็น**ปุ่ม ✕ แดงกลม** (แพทเทิร์น hover เดียวกับ `ShelfItemCard`)
- คลิกครั้งแรก → ปุ่มเปลี่ยนเป็นคำว่า **"ปิด?"** ค้าง 2 วินาที (กันคลิกพลาด — ไม่เด้ง dialog ให้รำคาญ), คลิกซ้ำภายในเวลานั้น → `NSRunningApplication.terminate()` (graceful quit — ถ้าแอปมีงานยังไม่เซฟ ระบบจะโชว์ dialog ของแอปเองตามปกติ)
- **Option+คลิก** = `forceTerminate()` สำหรับแอปค้าง
- ปุ่มโผล่**เฉพาะแถวที่เป็น GUI app** (มี `NSRunningApplication` และไม่ใช่ตัว OverlayLens เอง) — process ระบบอย่าง WindowServer/kernel_task **ไม่มีปุ่ม** (ปิด WindowServer = logout ทั้งเครื่อง)
- หลังปิดสำเร็จ แถวหายเองใน sample ถัดไป (≤2 วิ) ด้วย animation เดิมของ list

## 2. Visual language (ให้เข้าชุด widget เดิม)

ใช้สูตรเดียวกับ `DropShelfView` เป๊ะ ๆ เพื่อความเข้าชุด:

- พื้น: `RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.ultraThinMaterial)`
- ขอบ: `strokeBorder` gradient `white.opacity(0.35) → 0.08` (topLeading → bottomTrailing), lineWidth 1
- เงา: `shadow(color: .black.opacity(0.35), radius: 18, y: 8)`
- Chip gauge: วาดใน SwiftUI ล้วน (ไม่ใช้รูป asset — จะได้ redraw ตาม appearance และย่อขยายคม): ขาชิป = `ForEach` ของ `RoundedRectangle` เล็ก ๆ สีทองหม่น (`Color(red: 0.79, green: 0.64, blue: 0.31)`), package เทาเข้ม, progress ตาม `.trim` ที่อธิบายในข้อ 1
- Animation: ค่าที่เปลี่ยนทุก sample ให้ `.animation(.easeOut(duration: 0.6))` — bar/วงแหวนไหลนุ่ม ไม่กระตุก

### สีตามโหลด (heat colors)

ใช้เกณฑ์เดียวกับที่ `BatteryStatusController` ใช้กับแบต (เขียว/เหลือง/แดง) เพื่อภาษาเดียวกันทั้งแอป:

| ระดับ | CPU รวม | RAM (memory pressure) | อุณหภูมิ (thermal state) | สี |
|---|---|---|---|---|
| ปกติ | < 50% | pressure normal | `.nominal` | เขียวมิ้นต์ → ฟ้า gradient |
| เริ่มหนัก | 50–80% | pressure warn | `.fair` | amber (`systemOrange`) |
| หนัก | > 80% | pressure critical | `.serious` / `.critical` | แดง (`systemRed`) |

- แถบอุณหภูมิใช้ **thermal state เป็นตัวตัดสินสี** ไม่ใช่ตัวเลข °C (เกณฑ์องศาต่างกันตามชิป — M-series die วิ่ง 40–95°C ได้ปกติ; state คือสิ่งที่ระบบตัดสินให้แล้ว)

- วงแหวน + ตัวเลข % เปลี่ยนสีตามระดับ; แถบ bar ของแต่ละแอปใช้ gradient สีเดียวกับวงแหวนที่กำลังเรียงอยู่
- ตอน idle ทั้ง widget จะโทนขาว-ฟ้ากลืนไปกับกระจก — "มีสีเวลาทำงาน" คือสีจะสว่างขึ้นเมื่อโหลดขึ้นจริงเท่านั้น

## 3. Window behavior

สร้างตามแพทเทิร์น `DropShelfController` แต่ต่างตรง window level:

- `NSPanel` `[.nonactivatingPanel, .borderless, .fullSizeContentView]`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`
- **Level = desktop widget**: `NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))` — อยู่เหนือ wallpaper แต่ *ใต้* ทุกหน้าต่างแอป เหมือน widget ระบบ (ไม่ใช่ `.statusBar` แบบ shelf ที่ลอยทับทุกอย่าง)
- `collectionBehavior = [.canJoinAllSpaces, .stationary]`
- ตำแหน่ง default: มุมบนซ้ายของจอ ใต้แถว widget เดิม (`y ≈ visibleFrame.maxY - 360`, `x` ชิดคอลัมน์ widget) — ลากย้ายได้ (`isMovableByWindowBackground = true`) และ**จำตำแหน่ง**ใน `UserDefaults` key `SystemStatsFrame` (แพทเทิร์นเดียวกับ `DropShelfItems`)
- Toggle เปิด/ปิดจากเมนูของ status item เดิม (ไม่เพิ่ม icon ใหม่ใน menu bar — แถวเมนูเริ่มแน่นแล้ว)
- Panel ต้องรับ mouse event ได้ (ปุ่มปิดแอป/ลากย้าย/สลับโหมด) — อย่าตั้ง `ignoresMouseEvents`; hover ใน SwiftUI ใช้ tracking area ของ `NSHostingView` ซึ่งทำงานแม้ panel ไม่ active เพราะเป็น `.nonactivatingPanel`

## 4. Data sampling

ไฟล์ใหม่ `SystemStatsSampler.swift` — ทั้งหมดเป็น public API ไม่ต้องขอ permission เพิ่ม:

- **CPU รวม**: `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` เก็บ tick ต่อ core แล้วคิด delta ระหว่าง sample (ค่าแรกยังไม่มี delta — แสดง "—" ห้ามโชว์ 0%)
- **RAM รวม**: `host_statistics64(HOST_VM_INFO64)` → used = active + wired + compressed; ความจุจาก `ProcessInfo.processInfo.physicalMemory`; pressure จาก `DispatchSource.makeMemoryPressureSource`
- **ต่อ process**: `proc_listallpids()` + `proc_pid_rusage(RUSAGE_INFO_V4)`
  - CPU ต่อ process = delta ของ `ri_user_time + ri_system_time` / ช่วงเวลา (หน่วยเป็น mach ticks — แปลงด้วย `mach_timebase_info`)
  - RAM ต่อ process = `ri_phys_footprint` (ตัวเลขเดียวกับคอลัมน์ Memory ใน Activity Monitor — อย่าใช้ RSS เฉย ๆ จะเวอร์กว่าจริง)
  - process ของ user อื่น/system ที่อ่านไม่ได้ → ข้ามเงียบ ๆ (ไม่ error)
- **Group เป็น "แอป"**: จับคู่ pid → `NSRunningApplication` เพื่อได้ชื่อ + icon; process ลูก (Chrome Helper ฯลฯ) รวมยอดเข้า parent ผ่าน `responsible pid`; process ที่ไม่ใช่ GUI app (เช่น WindowServer) แสดงชื่อ process ตรง ๆ กับ icon gear
- **อุณหภูมิ**: สองชั้น —
  - **ตัวเลข °C**: enumerate เซ็นเซอร์ผ่าน `IOHIDEventSystemClientCreate` + matching dict `{PrimaryUsagePage: 0xff00, PrimaryUsage: 5}` (AppleSMC HID sensors) แล้วอ่าน `kIOHIDEventTypeTemperature` — เทคนิคเดียวกับแอป Stats (open source, ดูโค้ดอ้างอิงได้) ไม่ต้อง sudo/entitlement พิเศษ กรองเอาเฉพาะเซ็นเซอร์ชื่อขึ้นต้น "pACC"/"eACC"/"SOC" (CPU die) แล้วเฉลี่ย
  - **สี/สถานะ**: `ProcessInfo.processInfo.thermalState` (public API ตรง ๆ) + subscribe `thermalStateDidChangeNotification`
  - **Fallback**: ชื่อ HID sensor ต่างกันตามรุ่นชิป (M1→M4 ใช้คนละชุด) — ถ้า enumerate แล้วไม่เจอเซ็นเซอร์ CPU ให้ซ่อนตัวเลข °C เหลือแค่ป้าย thermal state (ห้ามโชว์ 0°C หรือค่ามั่ว)
  - **[implemented] เครื่องนี้ใช้ชื่อ `PMU tdie*` / `PMU2 tdie*`** (ไม่ใช่ pACC/eACC แบบ M1) — filter ต้องรับทั้งสองตระกูล; `tcal`/`tdev` เป็น calibration/device sensor (tdev1 อ่านได้ค่าติดลบมั่ว) อย่าเอามาเฉลี่ย
- **Cadence**: `Timer` ทุก **2 วินาที** บน background queue แล้ว publish ขึ้น `@MainActor` model; หยุด timer ตอน `NSWorkspace.willSleepNotification` / จอล็อก และตอน panel ถูกซ่อน — อย่าให้ widget วัดโหลดกลายเป็นตัวสร้างโหลดเอง (เป้า: ตัว sampler เองต้องกิน CPU < 1%)
- **[implemented] บทเรียน performance จริง**: ตัว sampler เบามาก (<1%) แต่ SwiftUI render ทับ `.ultraThinMaterial` ทุก tick กิน ~4–7% ของ 1 core — ลดด้วย (1) cache icon/`NSRunningApplication` ต่อ pid ไม่ดึงใหม่ทุก tick (2) ปัดเศษทุกค่าเป็น display precision แล้ว **ข้าม publish เมื่อ snapshot เท่าเดิม** (Equatable) (3) `.drawingGroup()` ที่ตัวชิป (4) **occlusion pause**: `NSWindow.didChangeOcclusionStateNotification` → หยุดวัดตอนโดนหน้าต่างบังมิด เหลือ ~1.7% เท่า baseline เพราะ widget ระดับ desktop โดนบังเกือบตลอดเวลาอยู่แล้ว
- แสดงเฉพาะ **top 4** (แถวที่เหลือรวมเป็น "อื่น ๆ อีก N แอป" บรรทัดเดียว)

## 5. ไฟล์ใหม่ + wiring

| ไฟล์ | หน้าที่ |
|---|---|
| `SystemStatsSampler.swift` | mach/libproc sampling ตามข้อ 4 |
| `SystemStatsController.swift` | NSPanel + positioning + persist frame (โครงเดียวกับ `DropShelfController`) |
| `SystemStatsView.swift` | SwiftUI: วงแหวนคู่ + app list (สไตล์ตามข้อ 2) |

Wiring ใน `AppDelegate`: instantiate ต่อจาก controller ตัวอื่น ๆ ตามแพทเทิร์นเดิม

## 6. ต้นทุน — ไม่กินโทเค็น ไม่ออกเน็ต

Widget นี้ **local 100%**: ทุกค่าอ่านจาก system API ในเครื่อง (mach / libproc / IOKit-HID / ProcessInfo) ไม่มี network call ไม่แตะ Claude API หรือบริการแปลใด ๆ → ใช้งานฟรี ไม่มีโทเค็น ไม่มี quota ต้นทุนเดียวคือ CPU ของตัว sampler เอง (เป้า < 1%) ส่วนของแอปที่ออกเน็ตยังคงมีแค่ translation lens (Google endpoint) กับ `ClaudeUsageTracker` (อ่าน usage อย่างเดียว) เหมือนเดิม

## 7. Gotchas ที่รู้อยู่แล้ว (จาก HANDOFF)

- `.nonactivatingPanel` → ไม่มี `applicationDidBecomeActive`; อะไรที่ต้อง refresh ตอนกลับมา ใช้ polling/notification เอง
- ตรวจงานด้วย `screencapture -R x,y,w,h` — computer-use มองไม่เห็นหน้าต่างของ LSUIElement app
- อย่า ad-hoc sign — ใช้ Dev Team `B97U594JRD` เดิม
