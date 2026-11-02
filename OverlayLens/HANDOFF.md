# OverlayLens — handoff (2026-07-20)

macOS menu-bar app: floating glass lens live-translates screen (SCK ~1fps → Vision OCR → translate, EN/TH/ZH). `[verified]` = checked just now; `[?]` = recalled only.

## State `[verified]`
- Builds clean; running instance = /Applications, build `20260720.1837`. **Deploy rule: always `./deploy.sh`** (build → ditto to /Applications → relaunch) — running from the build folder caused a stale-version incident (user relaunched old /Applications copy, removed icons reappeared). Verify via `ps -p $(pgrep -x OverlayLens) -o comm=`.
- 2026-07-20: **battery + Claude-status menu bar items DISABLED at user request** (battery drain concern) — not instantiated in `AppDelegate`; source files kept intentionally, don't delete. CPU/RAM widget toggle moved from battery dropdown → main MenuBarExtra menu (`OverlayLensApp.swift`, `onToggleStats`). Menu bar now: main magnifier + Drop Shelf only; stats widget floats at desktop level.
- Stats widget power, measured: ~2% of one core with quiet screen (2s pace visible / 10s covered / stops on sleep) — negligible; the real consumer is the lens OCR on changing screen content (bursts to 80%/core).
- 2026-07-20 (later): **lens no longer auto-starts** — `isLensVisible` starts false, `checkPermissionAndStart()` removed from launch, permission preflight moved into `setLensVisible(true)`; user must enable via menu/⌥⌘L each run. **Stats widget always shows on launch** (`SystemStatsController.init` calls `show()` unconditionally; toggle only hides for the current run). Both verified via screencapture + cpu-time (idle app+widget ≈ 1.9%/core, no capture indicator). Build `20260720.1852` deployed.
- Signing: real Dev Team `B97U594JRD` — keep; ad-hoc churns TCC grants every rebuild.
- **Uncommitted:** `AppDelegate.swift` (M) + new files: `BatteryStatusController.swift`, `DropShelfController.swift`, `DropShelfView.swift`, `ClaudeStatusController.swift`, `DogFace.imageset/`. Last commit `cda18cf`.
- `ClaudeStatusController` + DogFace came from a *parallel session*, not this one `[?]` — don't delete assuming they're orphans.

## This session added (2026-07-17)
- `BatteryStatusController.swift` — menu-bar battery: iOS-style icon drawn via `NSImage(size:flipped:drawingHandler:)` (redraws per appearance → labelColor adapts), % number inside, green >40 / amber 21–40 / red ≤20 (amber intentionally ≠ macOS Low Power yellow), ⚡ when charging. Thai dropdown menu (NSMenuDelegate, rebuilt per open): time-to-empty/full from IOKit `kIOPSTimeToEmptyKey`, charge-now advice, opens Battery Settings via `x-apple.systempreferences:com.apple.Battery-Settings.extension`. IOPS notify + 60s fallback timer.
- `DropShelfController/View.swift` — AirDrop staging shelf: status item (tray icon, swaps to `tray.full.fill` when non-empty), glass NSPanel top-center under notch (`.nonactivatingPanel`, `.statusBar` level), drop files → cards → one-button `NSSharingService(.sendViaAirDrop)`.
- Shelf now also accepts **images, not just files**: raw image data (browser drags; TIFF auto-converted to PNG) and `NSFilePromiseReceiver` promises (Photos) — both staged to `DropShelfModel.stagingDirectory` since AirDrop needs file URLs. Panel uses `.onDrop(of: [.fileURL, .image])` (note: `isTargeted` is a `Binding<Bool>`, not a closure); status item registers png/tiff + `NSFilePromiseReceiver.readableDraggedTypes`.
- Versioning: `MARKETING_VERSION = 1.1`; "Stamp build number" script phase writes `CFBundleVersion = yyyymmdd.HHMM` into the built product's Info.plist (needs `ENABLE_USER_SCRIPT_SANDBOXING = NO` + processed Info.plist declared as script **input** so it runs after ProcessInfoPlistFile; declaring it as output = "multiple commands produce" error). Battery %: no fill bar anymore, digits colored green/amber/red instead. Drop Shelf tray icon = systemBlue (non-template).
- Shelf **persists across relaunch**: item paths in `UserDefaults` key `DropShelfItems` (missing files filtered on load); staging dir moved tmp → `~/Library/Application Support/OverlayLens/DropShelf/`; staged copies deleted on remove/clear; badge refreshed once after `badgeHandler` is wired (restored items).
- User flow: system battery icon hidden via System Settings > Menu Bar (macOS Tahoe moved it out of Control Center).

## Quick translation: speed + whole-sentence frames (2026-09-16) `[verified]`
- `QuickTranslationController.swift` ("แปลจากหน้าจอ"): frozen screenshot → pick text → card. Two complaints fixed: slow to become usable, and the blue hover frame outlined a fragment instead of the sentence.
- **Measured on this Mac (2940×1912 shot, 114 lines): `usesLanguageCorrection` is 3× of the OCR cost** — accurate+correction 1.6–2.0s, accurate without 0.53s, `.fast` 0.22s but drops Thai lines (75/114). Correction changed 12/114 lines and was wrong about as often as right on screen text, so the full-screen pass now runs `OCRService.recognizeLines(in:languageCorrection: false)` (new default-true parameter; the lens pipeline still corrects). Downscaling to 0.5×/0.75× gained nothing (1.6s) — don't bother.
- The selector used to `NSImage(cgImage:).draw` the full 2x screen on **every mouse move**; the screenshot now sits on a layer-backed backdrop view (`layer.contents = image`) and `ScreenTextSelection` is a transparent overlay that only redraws when the outline changes.
- Vision splits one visual line wherever script or spacing changes (Thai/English mixes especially). `TextLayout` stitches pieces → rows (≥50% vertical overlap, gap < 1.2× height) → paragraph blocks (gap < 0.9× row height, x-ranges overlap, row height within 0.55–1.8× of the previous row, block ≤ 320pt / 45% of screen). Hover outlines the block; drag keeps pieces ≥50% covered (was: centre-point only, so clipped lines vanished).
- Wrapped lines of one paragraph are joined into one string for the translator (Latin: space, Thai/CJK: no separator; a paragraph gap keeps `\n`) — translating line-by-line broke sentences mid-thought. `lastSource` / "เก็บต้นฉบับ" store the joined text.
- Grouping was checked by rendering blocks over a real screenshot (scratch tool, not in repo); over-merges only appeared where translucent windows overlapped text.

## Drop Shelf: links & messages (2026-08-12) `[verified]`
- Shelf items are now `ShelfPayload = .file | .link | .text` — a group-work link (Meet/Zoom room) or a note rides along in the **same** AirDrop as the files. Add via: compose field in the shelf, clipboard button, or dragging a browser address bar / selected text onto the panel or the tray icon. Whole-string URLs become `.link` (NSDataDetector, must match the entire string, so "ห้องวันนี้ https://…" stays a message).
- **AirDrop payload rules, measured with `canPerform(withItems:)`**: file ✅, web URL ✅, mixes of file+URL ✅, **bare `NSString` ❌**. So `.text` items are written to `…/DropShelf/Messages/<first line>.txt` at send time (folder wiped at the start of each send); links go over as real URLs so the receiver gets a tappable link.
- Defaults key `DropShelfItems` now stores `"<kind>\t<value>"`; bare paths (old format) still load as files.
- Panel: `ShelfPanel: NSPanel` with `canBecomeKey = true` (borderless panels refuse key → compose field untypeable) + Esc closes via `cancelOperation`. **Must also set `hidesOnDeactivate = false`** — panels default to true, so the shelf vanished right after opening once it took key focus.
- Panel height follows content by measuring in SwiftUI (`GeometryReader` → preference → controller `setFrame`, top edge pinned via `panelTopY`). Do **not** use `NSHostingController.sizingOptions = [.preferredContentSize]` here: it crashed on open (`EXC_BAD_ACCESS`, "excessive recursion" inside CoreAutoLayout during `setFrame → displayIfNeeded → NSHostingView.layout`).
- Test harness note: `printf 'ไทย' | pbcopy` mangles UTF-8 (MacRoman); use `osascript -e 'set the clipboard to "…"'`.

## Identity: the mark (2026-08-12) `[verified]`
- `BrandMark.swift` owns the mark: the **Claude Code mascot**, redrawn from the user's reference as vector cells on a unit grid (`Brand.mascotCells/mascotPath`, SwiftUI `MascotShape`) — not a copied bitmap. Eyes are holes: fill with the **even-odd rule** (`FillStyle(eoFill: true)` in SwiftUI) or they fill in solid. Sprite is wider than tall (`Brand.aspect`), so size it **by height** and let width follow — that's what makes it readable at menu bar size.
- Placements: menu bar = 15pt-tall template image; lens header status light = same sprite at 13pt, tinted by `lensSignal`; app icon = cream tile + clay mascot tilted 5° (tilt and the tile drop out below 64px).
- Every icon decision was made by rendering candidates at the real 18pt/12pt sizes first (scratch contact sheets), not at poster size — corner brackets, text baselines and burst-in-frame all turned to mush small; that's why the three placements use different spoke counts and framing.
- App icons are generated by a script (clay tile 80.5% of canvas, corner radius 22.37% of tile, gradient + shadow, frame dropped below 64px) straight into `Assets.xcassets/AppIcon.appiconset` — regenerate rather than hand-editing PNGs.
- Brand colour is clay `#D97757` (`Brand.clay`), used for the "translating" state instead of the system accent. That freed orange, so **"no text found" is now a dashed grey border** rather than a second alert colour fighting the brand one.
- The spark also serves as the lens header's status light.

## Lens header + status border (2026-08-12) `[verified]`
- The clear lens carries a 26pt always-visible header: status dot + readout ("กำลังแปล · N บรรทัด" / "ไม่พบข้อความ" / "หยุดชั่วคราว"), a settings button, and close. It is the obvious grab handle, and it reports state a see-through frame otherwise hides.
- Border colour = `viewModel.lensSignal` (accent / secondary / orange / red), derived from `status`, `translationNote` and `recognizedLineCount`.
- Border, the invisible 14pt resize grab-ring (`Color.white.opacity(0.04)` — must stay non-zero, see the alpha rule below) and the header are all drawn in SwiftUI now; the panel's layer paints nothing. The middle is alpha 0 again, which means **clicks pass through to the app underneath** while the frame stays parked over it.
- `DragContainerView.hitTest` checks the top-right control strip *before* `permissionMode` so the header buttons work in every state; strip size matches the header height (60×26) so no dead band forms under it.
- The header's settings button opens the same controls popover via `MenuBarController.showControls(anchoredTo:)` — the way in when the status item is stranded under the notch. `[?]` popover-from-a-nonactivating-panel not verified from this session.

## Split lens: clear viewfinder + reader window (2026-08-12) `[verified]`
- The one combined glass lens is now **two panels**. `OverlayPanel` = lens 1, a clear see-through frame (no `NSVisualEffectView`, `hasShadow = false`, accent border on the container layer) that marks the capture region and draws AR patches in place. `ReaderPanel` (`ReaderPanel.swift`) = lens 2, the old glass window, showing the block translation wherever the user parks it.
- Both share `DragContainerView`. The reader passes only `onDragEnd → viewModel.readerMoved()` (saves `readerFrame`); it must **not** call `dragBegan/dragEnded`, which pause and restart capture. Hover is tracked separately (`isReaderHovering`) or hovering one window reveals the other's controls.
- `isReaderVisible` (`readerVisible` default, on by default) toggles the reader alone; `setLensVisible` drives both. Reader's first-run frame is placed beside the lens, flipping to its left when there's no room.
- **A fully transparent panel can't be dragged.** macOS routes mouse events by the window's alpha channel, so an alpha-0 interior passes clicks through to the app behind and only the 2pt border stays grabbable. The clear lens paints a ~3% accent wash (`container.layer?.backgroundColor`) — invisible in practice, keeps the whole surface draggable. Don't "optimize" it away.
- Nothing is drawn inside the clear frame (user's call): no AR patches over the source text. `arModeEnabled` now only means *translate line by line* and preserve line breaks in the reader — the menu row is labelled "แปลทีละบรรทัด" accordingly.
- AR mode now also joins its per-line translations into `translatedText` (`syncReaderTextFromSegments`), otherwise the reader — and the copy button — sit empty whenever AR mode is on.
- Capture already excluded every window owned by our pid (`CaptureEngine` filter), so the second window needed no extra handling.
- **⌥⌘L is gone** (user asked): the lens is toggled from the menu only. ⌥⌘D (shelf) remains.
- Testing note: the NSPopover menu is not in the accessibility tree and synthetic clicks don't reach the menu bar from a shell process, so UI paths there can't be driven from a session — verify by launching `/Applications/OverlayLens.app/Contents/MacOS/OverlayLens` directly with a temporary autostart hook, then remove it.

## Menu bar consolidation (2026-08-12) `[verified]`
- **Measured cause of "ไอคอนหาย"**: this Mac's menu bar is full — `NSScreen.auxiliaryTopLeftArea/RightArea` put the notch at x 646–825, and macOS parks the OverlayLens status item at x 799–833, i.e. *under the notch*. Nothing app-side can move it (order is user-controlled ⌘-drag); the fix is fewer items + paths that don't need the icon.
- App now uses **one status item** (`MenuBarController`) instead of two: left-click = controls popover (NSPopover + the old `MenuBarControlsView`), right-click/ctrl-click = Drop Shelf, drag onto icon = shelf, count badge = `button.title`. `MenuBarExtra` is gone from `OverlayLensApp` (scene is now `Settings { EmptyView() }`); `DropShelfController` no longer owns a status item.
- **⌥⌘D** toggles the shelf. `HotKeyManager` now filters on `EventHotKeyID` — its handler previously fired for *every* hotkey, so a second registration would have double-triggered both.
- ~~`EdgeDropZoneController` (left-edge drop strip)~~ — **removed 2026-08-12 at the user's request**: a 6pt invisible strip down the whole left edge was awkward in practice (it eats clicks at the screen edge and you can't see what you're aiming at). Don't reintroduce it; use drag-onto-icon or ⌥⌘D.
- Status item overlay (`StatusItemDropView`) is now pinned with constraints, not `autoresizingMask` — the item is `variableLength` and a frame captured at init stops covering the button once the badge changes its width (silently kills drops + right-clicks).
- Popover decluttered: the per-control grey captions moved into `.help` tooltips and every setting is now a `row(title, shortcut:, control:)` (669pt → 430pt tall). Keep new settings in that shape — captions under controls are what made it a wall of text.
- `[?]` Not verified from here: right-click on the icon and real drag-and-drop onto icon/edge strip — synthetic CGEvent clicks are blocked for this environment's processes and System Events' `click at` hits the wrong element. Verify by hand.

## Gotchas (this session)
- Drag-onto-status-item: overlay `NSView` subview on the button, `registerForDraggedTypes([.fileURL])`. **Don't** `hitTest→nil` (drops need hit-testing too); instead override `mouseDown` and re-send the button's action.
- Overlay buttons offset outside a card get clipped by ScrollView bounds — keep ✕ inside card.
- `pkill` then `open` same app: verify old PID actually died first — `open` silently no-ops (activates old instance) if still alive.
- Boring Notch (installed then fully removed at user request): prebuilt `MediaRemoteAdapter.framework` inside bundle keeps upstream Team ID → ad-hoc-signed main binary crashes at dyld ("different Team IDs"). Fix was `codesign --force --deep -s -` whole bundle. Its expanded size is hardcoded (`sizing/matters.swift openNotchSize`); proportional shrink = `.scaleEffect(open ? 0.5 : 1, anchor: .top)` on the layout, not smaller frame (content overflows).

## Prior gotchas (still true, from 2026-07-09 pass)
- Google Translate: never `sl=auto` on mixed EN+TH (biases to TH, silently returns input); pass detected source (`OverlayViewModel.translateWithFallback`).
- `.nonactivatingPanel` → no `applicationDidBecomeActive`; permission retry is polling-based.
- Vision boxes bottom-left origin; flip in `OverlayContentView.arPatch`.
- `defaults read com.overlaylens.OverlayLens directionOverride` before debugging "stuck" direction.
- Verify visually with `screencapture -R x,y,w,h` (computer-use can't see LSUIElement apps).

## Open next steps `[?]`
- Commit the 5 new files (one feature per commit: battery / drop-shelf / claude-status).
- Refresh /Applications copy. Shelf items don't persist across relaunch; no drag *out* of shelf.

## Portable lessons
- IOKit battery: `IOPSCopyPowerSourcesInfo` + `IOPSNotificationCreateRunLoopSource`; time estimates return -1 while recalculating — show "calculating…", never trust first read after plug/unplug.
- Rebuilding someone's open-source mac app locally: expect embedded prebuilt frameworks to break ad-hoc signing; `codesign --force --deep -s -` after copy.
- NSStatusItem accepting drops = invisible NSView overlay pattern (see gotcha above); NSStatusBarButton itself can't be made a drag destination cleanly.

## Meeting Notes (2026-10-01)
- ⌃⌥⌘R หรือเมนู "Meeting Notes": อัดเสียงระบบ (ScreenCaptureKit) + ไมค์ built-in -> Typhoon Whisper -> qwen3.5:9b สรุป
- ผลลัพธ์: ~/Library/Application Support/OverlayLens/Meetings/<date>_<app>/ (notes.md, transcript.md, *.caf, meta.json)
- First run: ปุ่ม install สร้าง venv (~1GB). ต้องอนุญาต Screen & System Audio Recording + Microphone
- LATER: live catch-up, glossary, auto-start per app, ทดสอบ AirPods Max/ไมค์จริงกับ Zoom
- (2026-10-01) ไฟล์ผลลัพธ์เป็นชื่อไทย: สรุป.md, ข้อความถอดเสียง.md, เสียงประชุม.caf, เสียงไมค์.caf, บันทึกระบบ.log (session เก่าที่เป็นชื่ออังกฤษยังเปิดได้). แก้คำศัพท์การตลาดอัตโนมัติ (meeting_notes.py FIXES/DEFAULT_GLOSSARY); เพิ่มคำเองที่ ~/Library/Application Support/OverlayLens/meeting-glossary.txt

- 2026-10-02 Meeting Notes: ASR now packs speech into ~8-min blocks with batch 16/8/4 (by free RAM); 67-min class ASR 34→26 min, transcript similarity 0.95. Combined notes: Meetings/2026-10-01_รวมทั้งคาบ.md. Backup of pre-speedup script was /tmp/meeting_notes.bak (VM, gone). LATER: MLX backend, overlap LLM with ASR, mic silent, session title.

- 2026-10-02 Meeting Notes: after summary, raw .caf → AAC .m4a (afconvert, 32 kbps), .caf deleted only if m4a decodes to same length (±1.5s). Disable: touch ~/Library/Application Support/OverlayLens/meeting-keep-raw. `meeting_notes.py <dir> --compress-only` converts old sessions. load_track reads .m4a via afconvert→wav. All 4 existing sessions converted (302 MB → 38 MB). UNTESTED: re-transcribing from .m4a.

- 2026-10-02 Meeting Notes LIVE mode (opt-in key MeetingLiveEnabled): while recording, `meeting_notes.py <dir> --live` (MeetingLiveWorker, background QoS) reads the still-growing .caf with a raw CAF parser (libsndfile calls it "malformed"), cuts at silence every ≥6 min of audio (MEETING_LIVE_CHUNK), transcribes finished stretches and checkpoints live.json; if free RAM ≥7 GB it also pre-writes finished section notes into live-sections.json (cache keyed by sha1(model+prompt)). On stop the worker is killed; the final pass transcribes only audio after the checkpoint and reuses cached section notes. Both temp files are deleted after success. Tested: growing-file parser, checkpoint+resume (67-min file: 11.4 min live → final 19.7 min, transcript sim 0.93). NOT tested: prewarm notes / cache hits, behaviour next to a real Zoom call. Disable: defaults write com.overlaylens.OverlayLens MeetingLiveEnabled -bool NO.

- 2026-11-01 Meeting Notes **import**: drop an audio/video file on the card (or "เลือกไฟล์…", or `defaults write com.overlaylens.OverlayLens MeetingImportPath <path>` + `notifyutil -p com.overlaylens.meeting.import`) and it gets the same transcript + notes as a recording. New files: `Meeting/MeetingImportLogic.swift` (naming/validation, symlinked into Tests/Logic), `Meeting/MeetingAudioImporter.swift` (afconvert → AVFoundation fallback). The import writes `เสียงประชุม.m4a` into a new `yyyy-MM-dd_HHmm_<filename>` session folder, plus meta.json with `importedFrom`, then runs the normal pipeline. **afconvert gotcha: `-b 64000` fails with "Couldn't set audio converter property ('!dat')" for one narrow-band channel** — the converter is pinned to `aac@16000 -b 32000 -c 1` (what the recogniser uses anyway). Tested end-to-end on build 20261101.1410: a .aiff handed to the running app → 16 kHz mono m4a → Thai transcript + notes in ~25 s; 86/86 logic tests (12 new, incl. real wav→m4a conversion and a garbage file rejected without leaving a stub).
