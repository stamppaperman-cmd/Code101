# OverlayLens — session summary (2026-07-09)

Built from scratch: a macOS menu-bar app that overlays a small floating glass lens anywhere on screen and live-translates whatever's underneath it, across three languages (English, Thai, Chinese), continuously (~1fps) as the screen changes.

## What shipped
- Floating draggable/resizable glass lens, hover-only controls, global hotkey (⌥⌘L), menu-bar quick settings.
- Live pipeline: screen capture → OCR (Vision, EN+TH+ZH) → translate → display, ~1fps.
- Translation: free online (Google) with automatic offline fallback (Apple on-device), auto-detects direction per text (Chinese→Thai, Thai→English, else→Thai), manual override (EN→TH / TH→EN / ZH→TH / Auto) for edge cases.
- Two display modes: classic (translated text block) and AR overlay (translation redrawn in-place over the original text's exact screen position).
- Proper code signing (permission grants now survive rebuilds), custom app icon.
- Full detail: `HANDOFF.md` in this repo (technical, for a Claude Code session).

## Current capabilities
- Works on any on-screen text: apps, browser, video subtitles, documents — anything Vision can OCR.
- No language picker needed — point it at English, Thai, or Chinese text and it detects and routes correctly per line, including all three mixed in the same frame (verified end-to-end).
- AR overlay mode visually verified — patches render in place, correctly positioned over the original lines.
- Runs standalone, no App Store, Developer ID-ready distribution setup.

## Known limitations
- Only EN/TH/ZH; Chinese only routes to Thai (not vice versa yet).
- Fixed rectangular lens; no shape/rotation options.
- Free translate API has no SLA — could rate-limit or change under heavy use; offline fallback exists but is lower quality.

## Ideas worth brainstorming
- Freeze-frame / snapshot mode (pause on a good frame instead of continuous re-OCR) for reading dense text.
- Export/share a translated snapshot.
- More language pairs, or auto-detect *any* language pair instead of a fixed set.
- Distribute via Developer ID installer / auto-update for non-technical users.
- History/log of recent translations for reference.
