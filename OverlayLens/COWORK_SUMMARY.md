# OverlayLens — session summary (2026-07-08)

Built from scratch this session: a macOS menu-bar app that overlays a small floating glass lens anywhere on screen and live-translates whatever's underneath it, in either direction (English ⇄ Thai), continuously (~1fps) as the screen changes.

## What shipped
- Floating draggable/resizable glass lens, hover-only controls, global hotkey (⌥⌘L), menu-bar quick settings.
- Live pipeline: screen capture → OCR (Vision, EN+TH) → translate → display, ~1fps.
- Translation: free online (Google) with automatic offline fallback (Apple on-device), auto-detects direction per text, manual override (EN→TH / TH→EN / Auto) for edge cases.
- Two display modes: classic (translated text block) and AR overlay (translation redrawn in-place over the original text's exact screen position).
- Proper code signing (permission grants now survive rebuilds), custom app icon.
- Full detail: `HANDOFF.md` in this repo (technical, for a Claude Code session).

## Current capabilities
- Works on any on-screen text: apps, browser, video subtitles, documents — anything Vision can OCR.
- Bidirectional without a language picker — just point it at text in either language, including both directions in the same frame (verified: mixed EN+TH screen content translates each line correctly).
- AR overlay mode visually verified — patches render in place, correctly positioned over the original lines.
- Runs standalone, no App Store, Developer ID-ready distribution setup.

## Known limitations
- English/Thai only — no other language pairs.
- Fixed rectangular lens; no shape/rotation options.
- Free translate API has no SLA — could rate-limit or change under heavy use; offline fallback exists but is lower quality.

## Ideas worth brainstorming
- Freeze-frame / snapshot mode (pause on a good frame instead of continuous re-OCR) for reading dense text.
- Export/share a translated snapshot.
- More language pairs, or auto-detect *any* language pair instead of EN⇄TH only.
- Distribute via Developer ID installer / auto-update for non-technical users.
- History/log of recent translations for reference.
