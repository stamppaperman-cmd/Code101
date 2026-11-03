# EchoNote — handoff (2026-09-06)

Offline Thai/English transcription + summarization for macOS. Built from scratch in one
session. Drag an audio or video file in, get raw text with timestamps, speaker labels, and
a summary. Nothing leaves the machine.

## State `[verified]`

- Builds and runs. **Always deploy with `./deploy.sh`** (same rule as OverlayLens) —
  launching from `build/` leaves `/Applications` stale.
- Installed build at time of handoff: `20260906.0042`.
- Full pipeline has completed end-to-end on a 64-minute Thai interview:
  871 segments, 4 speakers separated, summary produced, PDF exported.

## Stack

| Layer | Choice | Why |
|---|---|---|
| Decode | `AVAssetReader` → 16 kHz mono Float32 | no ffmpeg dependency; handles m4a/mp3/wav/mp4/mov |
| ASR | WhisperKit v1.1.0 (`argmaxinc/argmax-oss-swift`, MIT) | see rejected alternatives below |
| Diarization | SpeakerKit (same package, Pyannote CoreML) | free, offline, exposes speaker embeddings |
| Summary / cleanup | Ollama `qwen3.5:9b` at `127.0.0.1:11434` | free forever, no key, no quota |
| Storage | plain files + JSON under Application Support | readable by other apps; SQLite only when search arrives |

Models live in `~/Library/Application Support/EchoNote/models` (~4.4 GB).

## Rejected alternatives `[verified]`

- **Apple `SpeechTranscriber` (macOS 26)** — probed `supportedLocales`: 30 locales,
  **no Thai**. Fast and zero-download but unusable here. Re-check on OS updates.
- **Parakeet (FluidAudio)** — 25 European languages + Japanese + Mandarin, **no Thai**.
  Several popular macOS apps use it for speed; not an option for this workload.
- **Existing GitHub apps as a base** — searched and read source. `jassuwu/andrew-dictate`
  (meeting transcriber) ships `detectLanguage = true` and no `sampleLength`, i.e. both of
  the bugs fixed below. Code search found **almost no app that sets `sampleLength`**.
  Adopting one would have imported the bugs.

## Bugs found and fixed this session `[verified]`

1. **Finished jobs came back as "failed".** `summarize()` called `complete(job)` (which
   wrote status `done`) and then `store.writeSummary(job)` with the *pre-complete* copy,
   stamping `summarizing` back onto disk. On next launch the recovery logic saw a running
   status and marked it failed. Fixed by having `complete` return the updated job.
   `JobStore.load()` now also repairs and **persists** interrupted jobs.
2. **Whisper wrote fluent English mid-Thai-interview.** `detectLanguage: true` re-detects
   per window; a noisy passage got labelled English and the model invented sentences.
   Fixed: detect once across 5 probes, then pin `language` and set `detectLanguage: false`.
3. **Wrong model auto-selected.** The rule `contains("large-v3") && contains("turbo")`
   matched `distil-whisper_distil-large-v3_turbo`, which is **English-only**. Now filters
   out `distil` and `.en` before ranking.
4. **Progress bar could run backwards.** `fillGaps` and `diarize` both wrote into
   0.55–0.57. Replaced hand-written weights with `PipelineStage` — one ordered list that
   both the bar and the time estimate read from.
5. **Models cluttered `~/Documents/huggingface`** (WhisperKit's HubApi default). Moved to
   Application Support. **An orphaned 1.4 GB `distil-whisper` model is still sitting in
   `~/Documents/huggingface` — safe to delete, nothing uses it.**

## Whisper silently drops audio `[verified problem, verified fix]`

Measured on the 64-minute interview:

| Mode | Audio covered by transcript | Zero-length segments |
|---|---|---|
| fast (VAD chunking) | 83.4% | 23 |
| accurate (sequential) | **74.3%** | **58** |

**26% of the audio produced no text at all**, across 32 stretches (one was 70 seconds).
Zero-length segments are cut mid-word (`ภาพรวมของเทอเทิลก`, `แล้วก็เห`).

Root cause, confirmed in the library source — `Sources/WhisperKit/Core/TextDecoder.swift:577`:

```swift
let loopCount = min(initialPromptIndex - 1 + options.sampleLength, Constants.maxTokenContext - 1)
```

`Constants.maxTokenContext = 448 / 2 = 223` — half of Whisper's real 448-token text
context. Thai costs 2–3 tokens per character, so a dense 30-second window exhausts the
budget, decoding stops, and the rest of that window is skipped. **Raising
`DecodingOptions.sampleLength` does nothing** — it is clamped. (I tried it first; it was
inert. Do not repeat that.)

**The fix, verified 2026-09-06:** `TranscriptionEngine.fillGaps(...)` measures uncovered
stretches ≥6 s after the first pass and re-transcribes each slice on its own, so each
starts its token budget from zero. Wired in as pipeline stage `.fillGaps`.

Same file, same accurate mode, same `openai_whisper-large-v3`:

| | before | after |
|---|---|---|
| Coverage | 74.3% | **92.4%** |
| Stretches with no text | 32 (26% of audio) | **4 (110 s, 2.9%)** |
| Segments | 871 | 1092 |

The four remaining gaps are 30 s, 30 s, 30 s and 20 s — one Whisper window each, which
is what `fillGaps` cannot recover when the re-transcribed slice also returns nothing.
56 zero-length segments remain (was 58), so the mid-word cut itself is untouched — only
its consequence is.

**Cost: the run went from ~56 min to ~96 min.** `ถอดเสียง` alone went 15 → 54.5 min and
`เก็บตก` added 15 min. Part of that is real work — text that used to be dropped now gets
decoded — but one run cannot separate that from the block splitting below. **A/B this
before trusting either number.**

### Why the earlier verification run died `[cause still open]`

The failure was **not** in `fillGaps`. `job.json` for the failed run says
`currentStage: transcribe`, `progress: 0.3545`, `segments: 0` — with transcribe spanning
0.04–0.50 of the bar that is 68% of the audio, ~43 minutes in, in the main pass.

It died the same way twice more on 2026-09-06: process gone, **no `.ips` crash report, no
`log show` output, no jetsam entry**. That is a SIGKILL or a CoreML fault taking the
process down, not a Swift error — `catch` cannot see it.

The model is not corrupt: `large-v3` is complete at 2.9 GB, no zero-byte files,
`weight.bin` present in all three (1.2G / 368K / 1.7G). **Do not delete and re-download
it** — that was the old guess and it costs 2.9 GB for nothing.

**2026-09-07, caught in the log at last.** A fourth death, this time during `สรุป`:

```
00:21:20.122 [    82 MB] stage summarize begin
<process gone>
```

**EchoNote's own footprint was 82 MB.** System swap was at 12.5 GB. The app is not the
thing consuming memory — it is being killed as collateral damage while Ollama holds the
RAM, which is why nothing ever appeared in its own crash reports. Look at the daemon's
appetite, not this app's.

The transcript survived this one: 13 segments on disk, `summary: false`, recovered on
next launch as done with "กด สรุปใหม่". That is `keepPartial` doing exactly its job — the
same death used to cost the entire run.

Memory is the live suspect but is not yet proven for the transcribe stage. Sampled
through the successful run: swap held at **47 MB for all of transcribe and fillGaps**,
then climbed to **10.4 GB** during `เกลาคำ` and `สรุป` (the Ollama stages), with EchoNote's
own RSS paged down to ~30 MB. So the LLM stages do exhaust 16 GB — but they are not where
the deaths happened.

**Two changes now limit the blast radius** (`TranscriptionEngine.transcribe`,
`AppModel.keepPartial`): the audio is cut into ~10-minute blocks at the quietest 20 ms
frame within ±20 s of each boundary, and each block retries once before being left to
`fillGaps`; segments are written to disk as each block lands. A throw now costs one block.
A process death now costs the last block instead of the whole hour — which is what the two
lost runs cost.

## Guarding the LLM `[verified]`

A 9B model rewrites facts while looking fluent. Measured examples: it turned
`ภายในวันสุขนี` (ศุกร์) into `ภายในวันนี้`, dropped `หน้า` from `วันจันหน้า`, deleted the
word `เป็น` from a sentence, wrote `อายุ 38 ปี` where the transcript said `31`, and leaked
Chinese characters (`更多人`) into Thai output.

Prompting alone did not stop any of it. What works:

- **`TextCorrector`** — dates, times and numbers are masked to `§n§` before the model sees
  them and restored verbatim after. Segments go out numbered and must come back 1:1 or the
  whole batch is discarded. Each line is then re-checked for digit preservation and length
  ratio **0.95–1.15** (the original 0.7 floor let word deletions through). A deterministic
  `knownFixes` table runs first and always lands.
- **`SummaryAudit`** — flags numbers, Thai weekdays/months and CJK characters that appear
  in the summary but not in the transcript. Surfaced in the UI and carried into the PDF.
- **Raw text is never overwritten.** `Segment.corrected` is additive; the reader has a
  raw/corrected toggle and corrected lines are tinted.

## Grounding: every claim carries its evidence `[built 2026-09-06]`

The goal was to match NotebookLM's reliability offline and for free. What makes that tool
trustworthy is not the size of its model — it is three architectural properties, none of
which need a large model:

1. answers are restricted to a source set,
2. every claim carries a marker back to the line it came from,
3. anything outside the sources gets a refusal rather than a paragraph.

EchoNote already had the hardest part: `Segment.text` is never overwritten, so a raw copy
always exists to check against. The rest is now built.

**Where the numbers live.** `Summarizer.chunk` emits `#<id> [12:34] text`, both prompts
require `[#42]` markers on every statement, and `Citations.claim(from:validIds:)` splits a
model line into `Claim { text, segmentIds, invalidIds }`. Citations pointing at segments
that do not exist are kept in `invalidIds` and shown in red — a model inventing its own
evidence is the failure this layer exists to catch, so it is surfaced rather than dropped.

`bullets` and `actions` still hold plain sentences; the claims sit beside them in
`citedBullets` / `citedActions`. Everything that already read a summary keeps working, and
a summary written before citations existed still renders.

**The check that has no text-only equivalent.** `SummaryAudit.located` compares each claim
against the whole transcript *and* against the lines it actually cited. A fact that is in
the transcript but not in the cited lines is real but bolted to the wrong moment — a
summary that reads perfectly and is still wrong. Nothing short of a citation can see that
class of error, and it is now reported as `อ้างผิดที่`.

**The advantage NotebookLM cannot have.** A citation here points at audio, not at text.
`CitationChip` plays the recording at that second, so a transcription error does not
survive the check — the transcript is not the evidence, the recording is.

**Asking questions.** `Retriever` embeds three-segment windows (one segment of overlap)
with `nomic-embed-text` and stores them in `embeddings.json` beside the transcript;
`Asker` retrieves the top 8, shows the model those lines and nothing else, and drops any
answer sentence that cannot name a line. `ไม่พบคำตอบในไฟล์นี้` is a first-class outcome,
returned before the model is even called when the best similarity is under 0.35.

Note the prefixes: nomic-embed-text is trained with `search_document: ` and
`search_query: ` and is measurably worse without them. They are interface, not decoration.

### `nomic-embed-text` does not read Thai `[measured 2026-09-06]`

The embedding retrieval described above was built, shipped, and then found not to work.
Three unrelated Thai questions — "สาขาภูเก็ตทำยอดได้เท่าไหร่", "วิธีเปลี่ยนยางรถยนต์" and
"สูตรทำต้มยำกุ้ง" — produced **byte-identical** similarity scores against the same two
windows: `(0.5957, 0.7454)` every time. An English question moved the numbers. The model
returns a near-constant vector for Thai, so ranking by cosine was ranking by nothing, and
the 0.35 relevance floor could never fire.

The replacement is `Lexical.swift`: character trigrams with tf-idf cosine. Thai has no
spaces, which rules out word tokenisation, but two passages about the same subject share
a great many trigrams anyway. It needs no model and no download, and its scores are
honest — a question sharing nothing with the transcript scores exactly `0.0`, which is
what makes `Asker.relevanceFloor` (now `0.02`) mean something.

Measured on the same fixture: relevant question `0.22`, tangential `0.098`, unrelated
`0.0`.

Vectors are still built when an embedding model is present, but are used only after
`Retriever.vectorsAreInformative` proves they separate windows that share almost no
words. **Unproven means unused** — lexical ranking is measured to work, and blending an
unvalidated signal into a working one can only make it worse. That check is what stopped
a `0.6 lexical + 0.4 embedding` blend from scoring an irrelevant question at `0.298`.

If someone wants embeddings to actually help here, the fix is a multilingual model
(`bge-m3`, `snowflake-arctic-embed2`), not a different threshold.

**Do not reach for `gemma4:26b`.** It is on this machine at 18 GB, on 16 GB of RAM. It
must page, and the Ollama stages already drive swap to 10 GB with the 9B model. A 9B model
forced to cite every sentence is more trustworthy than a 26B model talking freely, and it
is the only one of the two that fits.

## Speaker separation `[verified]`

4 speakers on the interview, 93% of segments attributed, main speaker (68% talk time)
correctly identified as the interviewee. `SpeakerNamer` reads the transcript for
introductions and proposes names with the evidence sentence, shown as `ชื่อ (เดา)` until
the user confirms. Names typed by the user are never overwritten.

**Fixed 2026-09-06 — names were attributed to the wrong voice.** On the interview the
model read `พี่แปลงกวา ตอนนี้อายุเท่าไหร่ครับ` — the interviewer *addressing* the
interviewee — and gave the interviewer that name. Addressing someone by name is evidence
about the person addressed, never about the person speaking, and no prompt wording made a
9B model reliably tell those apart.

`SpeakerNamer.accept(_:segments:)` now checks the direction instead: find who actually
said the evidence sentence; if it is the same speaker the name is being given to, the
sentence must be an introduction; if it is someone else, being named is exactly what that
looks like and it stands. Evidence that cannot be found in the transcript at all was
invented and is dropped. Covered by `SpeakerNamerTests` using the real sentences.

**Not built yet, but the API supports it:** `DiarizationResult.speakerCentroidEmbeddings`
exposes per-speaker vectors — enough to remember a voice across files so a name typed once
carries forward.

## Custom vocabulary `[built 2026-09-07 — two approaches measured and discarded first]`

A user-editable list of names, brands and jargon (settings bar → "คำเฉพาะ"). It reaches
the **cleanup pass** as context, not the decoder. The route matters more than the feature,
because the two obvious routes were both built and both measured worse.

**1. Whisper's `initial_prompt` (`DecodingOptions.promptTokens`) — measured worse.**
On the 45-second test meeting with a 48-token list:

| | without | with |
|---|---|---|
| `แคมเป็น` → `แคมเปญ` | ✗ | **✓** |
| `ไตรมาตร` → `ไตรมาส` | ✗ | **✓** |
| segments | 13 | **2** |
| text lost | none | **a sentence, cut at `โดยเน`** |

WhisperKit caps the prompt at `(maxTokenContext / 2) - 1 = 110` tokens and spends them
out of the same 223 the transcript needs — the exact budget whose exhaustion is why this
app drops audio. Three spellings bought; a sentence and every intermediate timestamp
lost. **Do not re-enable it without re-running that comparison.**

**2. Fuzzy substring replacement in the finished text — corrupts correct text.** Thai has
no spaces, so there is no boundary to anchor a match to, and every objective tried picked
the wrong span. Closest-match prefers a *prefix* of the misspelling (`ไตรมา` is one edit
from `ไตรมาส`, `ไตรมาตร` is two) and produced `ไตรมาสตร`. Longest-match swallows what
follows and turned `ไตรมาสนี้กับ` into `ไตรมาสบ`. Both were caught by tests before
shipping; neither is salvageable without word segmentation.

**3. What shipped:** the list is appended to `TextCorrector`'s system prompt as a
whitelist of correct spellings. That pass already masks dates and numbers out of the
model's reach, discards any batch whose reply is not 1:1, re-checks every line for digit
preservation and length ratio, and writes only `Segment.corrected` — the raw transcript
is never touched. Zero decode cost, no string surgery, and every guard against the model
overreaching was already built and tested.

Whisper's temperature fallback was already active — `temperatureFallbackCount: 5`,
`compressionRatioThreshold: 2.4`, `logProbThreshold: -1.0` are WhisperKit defaults and
this app never overrode them. Nothing to enable there; do not "fix" it twice.

## Performance `[verified]`

Measured on M5 / 16 GB, 64-minute Thai audio:

| Stage | Time | Note |
|---|---|---|
| Transcribe (accurate) | ~15 min → **54.5 min** | 4.26× → 1.17× realtime after gap recovery |
| Transcribe (fast) | ~7 min | ~8.5× realtime |
| Diarize | ~3 min | |
| Fill gaps | **15.0 min** | new stage; recovers the audio Whisper dropped |
| Correct | ~25 min → **15.1 min** | ConcurrentMap(3) measured, was 44 serial Ollama calls |
| Index | ~40 s (est.) | `nomic-embed-text`, ~550 windows in batches of 32 |
| Summarize | ~6 min | 10 serial calls |

Correction should now fall by roughly another 4× — only the least confident 25% of
segments is sent to the model — but that is arithmetic, **not yet measured**.

`PipelineStage.defaultRate` was reseeded from the 2026-09-06 run; the old seeds were taken
from a run that dropped a quarter of the audio and were therefore optimistic.

The bottleneck was never the ASR — it was 58 Ollama requests waiting in line. Fixed with
`ConcurrentMap` (3 at a time) and batch size 20→30; the ASR model is also unloaded before
the LLM stages so 16 GB can hold both. **Expected ~4× on correction, not yet measured.**

`StageRates` learns seconds-per-audio-second per stage per quality mode into UserDefaults
(60/40 blend) and drives the ETA. Seeded from the numbers above.

## Gotchas

- **`deploy.sh` refuses to run while a job is in flight.** It lists what would be lost and
  exits; `./deploy.sh --force` overrides. Four jobs were killed this way before the check
  existed, because "remember to look at job.json first" is not a check.
- **"แม่นยำสูง" was a lie** — accurate mode spells better but drops *more* audio. Renamed
  to `คำแม่นสูง` with the trade-off in the tooltip. Do not undo that honesty.
- `SpeakerKit` does not re-export `ArgmaxCore`; `DiarizationEngine.swift` needs
  `import WhisperKit` for `ModelDownloadConfig`.
- The API name is `detectLangauge` — the typo is in the library.
- **There is a log now:** `~/Library/Application Support/EchoNote/echonote.log`, one
  previous run kept beside it. Every line carries the process footprint in MB, and block
  boundaries are flushed *before* the work starts — so if the process is killed rather
  than returning, the last line says what it was doing and how much memory it held.
- Stage/progress updates only reach disk on 5% steps and stage changes. Reading `job.json`
  from outside will look stale mid-stage; that is by design, not a hang. Confirm with a
  stack sample before assuming the app is stuck (it wasn't, twice).

## Privacy posture `[verified]`

Audited the whole source: the only outbound host in app code is `http://127.0.0.1:11434`
(Ollama); the only one in the library is `https://huggingface.co` (model downloads). No
analytics, no telemetry, no special entitlements. **Audio, transcripts and summaries never
leave the machine.**

**One opt-in exception, added 2026-09-07.** The "ถาม" tab can send the question and the
raw transcript to Google's free Gemini tier instead of the local model. It is off by
default, never selected on the user's behalf, states the consequence next to the picker
every time, and records on each stored answer which model produced it. The audio file is
never sent — only text. The API key lives in the Keychain (`Secrets.swift`), never in
`UserDefaults`, and travels in an `x-goog-api-key` header rather than a query parameter
so it cannot end up in a proxy log.

Only the raw transcript goes, never the summary: the summary is a 9B model's output, and
handing it to a second model invites the first one's mistakes to be repeated with more
confidence.

`offlineOnly` ("โหมดปิดระบบ") blocks the catalogue lookup and all downloads, using only
models already on disk. For an air-gapped install: copy the `models` folder across, turn
the switch on. Updating is just replacing the `.app` — data and models are untouched.

## Tests `[built 2026-09-06]`

`EchoNoteTests` — 51 tests, all passing, `xcodebuild -scheme EchoNote test`. A host-based
unit bundle, added by hand to a `objectVersion = 70` project (synchronized groups, so new
files in `EchoNoteTests/` are picked up without touching the project file again).

They cover only the functions that stand between a model and the user's data, because
those are the ones that fail silently: a bad correction reads like a good one, a citation
pointing at the wrong line looks exactly like one pointing at the right line. The cases
are not invented — each is either measured output from the 64-minute interview or the
exact shape of a bug that reached a user (`เรียนเป็นเด็ก…` → `เรียนเด็ก…`, `31` → `38`,
the leaked `更多人`, the misattributed speaker name).

**They immediately earned it.** `Citations.parse` reversed the ids inside a single marker:
`[#42, #43]` came back as `[43, 42]`. Silent, plausible, and it would have pointed every
multi-citation claim at the wrong line first. Caught by the second test written.

## Open next steps `[?]`

Done since the last handoff: low-confidence-only correction, timestamps in the summary,
click-timestamp-to-play, dedupe by file hash, resume from persisted segments, test target.

1. **Measure the vocabulary pass on the 64-minute file.** It is verified to reach the
   cleanup prompt and verified not to cost transcript, but whether a 9B model actually
   fixes `แปลงกวา` → `แต่งกวา` across an hour is unmeasured.
2. **A/B the block splitting.** `ถอดเสียง` went 15 → 54.5 min in the same run that took
   coverage 74.3% → 92.4%. Some of that is real work — text that used to be dropped now
   gets decoded — but one run cannot separate it from the cost of splitting. Run the same
   file with `AudioBlocks.blockSeconds` set past the file length to get the unsplit number.
3. **Why the process dies during transcribe.** Three deaths, no crash report either time.
   The log now records footprint per block; the next death will say whether memory was the
   cause. Do not delete the model — it is complete.
4. Live text while transcribing; remember a voice across files via
   `DiarizationResult.speakerCentroidEmbeddings`.
5. **Retrieval is lexical only.** Character trigrams work and are honest, but they match
   spelling, not meaning — a question phrased in different words than the recording used
   will miss. A multilingual embedding model (`bge-m3`, `snowflake-arctic-embed2`) would
   fix that; `Retriever` already blends vectors in as soon as
   `vectorsAreInformative` proves they separate anything.
6. **Gemini is wired but unexercised.** The path, the key handling and the citation
   validation are built and unit-tested; no real question has been asked through it,
   because that needs the user's own API key.

## Portable lessons

- **Verify the fix, not the edit.** `sampleLength: 400` compiled, read sensibly, and did
  nothing. One grep into the library caught it before it was reported as fixed.
- **A small model will lie fluently.** Every point where it touches data needs a
  programmatic check, not a firmer prompt. Keep the raw copy so any claim stays auditable.
- **Measure before blaming the obvious suspect.** The ASR looked slow; the real cost was
  58 serialized LLM calls. The numbers said so, guessing did not.
- **Silence is the dangerous failure.** Whisper dropped a quarter of the audio without a
  single error. Coverage is now computed and shown for exactly that reason.
