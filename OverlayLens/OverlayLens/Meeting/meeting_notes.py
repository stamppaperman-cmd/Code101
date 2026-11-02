#!/usr/bin/env python3
"""
meeting_notes.py — OverlayLens Meeting Recorder pipeline (100% local, free).

  session_dir/system.caf  (+ optional mic.caf)   16 kHz mono PCM, written by OverlayLens
        │  ASR: typhoon-ai/typhoon-whisper-turbo (Thai fine-tuned Whisper)  — transformers + Apple MPS
        ▼
  transcript.md            timestamped, speaker-labelled (ประชุม = system audio, ผม = mic)
        │  LLM: Ollama (qwen3.5:9b by default, auto-detected)  — map-reduce for long meetings
        ▼
  notes.md                 Thai study / meeting notes

stdout protocol (parsed by the app):
  @@STATUS {"stage": "...", "pct": 0-100, "msg": "..."}
  @@DONE   {"notes": "...", "transcript": "..."}
  @@ERROR  {"msg": "..."}

Usage:
  meeting_notes.py <session_dir> [--title T] [--context C] [--llm NAME] [--skip-summary]
  meeting_notes.py <session_dir> --summarize-only        # reuse an existing transcript.md
"""
import argparse, shutil
import datetime as dt
import difflib
import gc
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import time

SR = 16000
ASR_MODEL = os.environ.get("MEETING_ASR_MODEL", "typhoon-ai/typhoon-whisper-turbo")
OLLAMA = os.environ.get("OLLAMA_HOST_URL", "http://localhost:11434")
PREFERRED_LLMS = ["qwen3.5:9b", "qwen3:8b", "qwen3.5", "qwen3", "qwen2.5:7b", "llama3.1:8b", "gemma3:12b", "gemma3", "gemma4:26b"]
SECTION_CHARS = 5000          # size of one detailed-notes chunk
OVERVIEW_BUDGET = 12000       # chars of detailed notes fed to the overview step
WHO = {"system": "ประชุม", "mic": "ผม"}

HALLUCINATIONS = [
    "ขอบคุณที่รับชม", "ขอบคุณที่ติดตาม", "กดติดตาม", "สมัครสมาชิก", "อย่าลืมกด",
    "ซับไตเติ้ล", "ซับไทย", "แปลโดย", "subtitles by", "thanks for watching",
    "thank you for watching", "www.",
]


# --------------------------------------------------------------------------- util
def emit(tag, **payload):
    print(f"@@{tag} {json.dumps(payload, ensure_ascii=False)}", flush=True)


def status(stage, pct, msg=""):
    emit("STATUS", stage=stage, pct=int(pct), msg=msg)


def fmt_ts(sec):
    sec = int(max(0, sec))
    return f"{sec // 3600:02d}:{sec % 3600 // 60:02d}:{sec % 60:02d}"


def parse_ts(s):
    h, m, sec = (int(x) for x in s.split(":"))
    return h * 3600 + m * 60 + sec


# --------------------------------------------------------------------------- audio
def _to_wav(path):
    """libsndfile cannot read AAC; macOS afconvert can (16 kHz mono PCM temp file)."""
    import tempfile
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="olm-")) / "a.wav"
    subprocess.run(["afconvert", str(path), str(tmp), "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"],
                   check=True, capture_output=True, timeout=900)
    return tmp


def load_track(path):
    import numpy as np
    import soundfile as sf
    tmp = None
    if str(path).lower().endswith(".m4a"):
        path = tmp = _to_wav(path)
    try:
        data, sr = sf.read(str(path), dtype="float32", always_2d=True)
    finally:
        if tmp:
            shutil.rmtree(tmp.parent, ignore_errors=True)
    x = data.mean(axis=1)
    if sr != SR and len(x):
        n = int(len(x) * SR / sr)
        x = np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x).astype("float32")
    return x


KEEP_RAW = pathlib.Path.home() / "Library/Application Support/OverlayLens/meeting-keep-raw"
RAW_NAMES = {"system": ["เสียงประชุม", "system"], "mic": ["เสียงไมค์", "mic"]}


def find_audio(d, name):
    for base in RAW_NAMES[name]:
        for ext in (".caf", ".m4a"):
            p = d / (base + ext)
            if p.exists():
                return p
    return None


def compress_audio(d):
    """Raw .caf → AAC .m4a (~10x smaller). The .caf is removed only after the m4a is verified
    to decode to the same length; any doubt keeps the original. Touch meeting-keep-raw to disable."""
    import soundfile as sf
    done = []
    if KEEP_RAW.exists():
        return done
    for name in RAW_NAMES:
        for base in RAW_NAMES[name]:
            src = d / (base + ".caf")
            if not src.exists() or src.stat().st_size < 8192:
                continue
            dst = src.with_suffix(".m4a")
            try:
                subprocess.run(["afconvert", str(src), str(dst), "-f", "m4af", "-d", "aac", "-b", "32000"],
                               check=True, capture_output=True, timeout=900)
                tmp = _to_wav(dst)
                try:
                    a, b = sf.info(str(src)), sf.info(str(tmp))
                    ok = abs(a.frames / a.samplerate - b.frames / b.samplerate) < 1.5 and dst.stat().st_size > 1024
                finally:
                    shutil.rmtree(tmp.parent, ignore_errors=True)
                if ok:
                    src.unlink()
                    done.append(f"{src.name}→{dst.name}")
                else:
                    dst.unlink(missing_ok=True)
            except Exception:
                dst.unlink(missing_ok=True)
    return done


def active_regions(x, win=0.5, pad=1.0, merge_gap=2.5, min_len=0.6, max_len=300.0):
    """Return [(start_s, end_s)] where there is signal.

    The threshold adapts to the noise floor but is clamped to −50…−40 dBFS: with
    non-stop speech the "floor" percentile is itself speech, and an unclamped
    threshold would discard the whole recording.
    """
    import numpy as np
    n = int(win * SR)
    frames = len(x) // n
    if frames == 0:
        return []
    chunk = x[: frames * n].reshape(frames, n)
    db = 20 * np.log10(np.sqrt((chunk ** 2).mean(axis=1)) + 1e-9)
    floor = float(np.percentile(db, 10))
    thr = min(max(-50.0, floor + 10.0), -40.0)
    act = db > thr
    regions, start = [], None
    for i, a in enumerate(act):
        if a and start is None:
            start = i
        if (not a) and start is not None:
            regions.append([start * win, i * win])
            start = None
    if start is not None:
        regions.append([start * win, frames * win])
    merged = []
    for r in regions:
        if merged and r[0] - merged[-1][1] < merge_gap:
            merged[-1][1] = r[1]
        else:
            merged.append(r)
    total = len(x) / SR
    out = [(max(0.0, s - pad), min(total, e + pad)) for s, e in merged if e - s >= min_len]
    if not out and float(db.max()) > -55.0:          # very quiet but not silent: try everything
        out = [(0.0, total)]
    return split_long(out, db, win, max_len)


def split_long(regions, db, win, max_len):
    """Cut regions longer than max_len at the quietest half-second near the cut."""
    out = []
    for s, e in regions:
        while e - s > max_len * 1.15:
            target = s + max_len
            lo = int(max(s, target - 20) / win)
            hi = int(min(e, target + 5) / win)
            cut_i = lo + int(db[lo:hi].argmin()) if hi > lo else int(target / win)
            cut = cut_i * win
            if cut <= s + 30:
                cut = target
            out.append((s, cut))
            s = cut
        out.append((s, e))
    return out


# --------------------------------------------------------------------------- ASR
def repetition_ratio(text, n=6):
    """Share of distinct character n-grams (1.0 = no repetition). Language-agnostic:
    zlib on UTF-8 is useless here because Thai bytes compress ~2.5x even when natural."""
    t = re.sub(r"\s+", "", text)
    if len(t) < n * 4:
        return 1.0
    grams = [t[i:i + n] for i in range(len(t) - n + 1)]
    return len(set(grams)) / len(grams)


def is_junk(text):
    t = text.strip()
    if len(t) < 2:
        return True
    low = t.lower()
    if any(h in low for h in HALLUCINATIONS):
        return True
    if len(t) > 60 and repetition_ratio(t) < 0.3:       # "ขอบคุณค่ะขอบคุณค่ะ…" style loops
        return True
    return False


def build_asr():
    import torch
    from transformers import pipeline
    if torch.backends.mps.is_available():
        device, dtype = "mps", torch.float16
    else:
        device, dtype = "cpu", torch.float32
    asr = pipeline("automatic-speech-recognition", model=ASR_MODEL, torch_dtype=dtype, device=device)
    return asr, device


_LOOP = re.compile(r"(.{1,15}?)\1{3,}", re.S)


def collapse_loops(text):
    """Whisper sometimes gets stuck repeating one syllable ("บุ๊บปุ๊บปุ๊บ…"). Keep it once.
    Returns (clean_text, fraction_of_text_that_was_loop)."""
    before = len(text)
    prev = None
    while prev != text:
        prev = text
        text = _LOOP.sub(r"\1", text)
    return text.strip(), (1 - len(text) / before) if before else 0.0


def free_gb():
    try:
        out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=5).stdout
        page = int(re.search(r"page size of (\d+)", out).group(1))
        free = sum(int(re.search(rf"{k}:\s+(\d+)", out).group(1)) for k in ("Pages free", "Pages inactive", "Pages purgeable"))
        return free * page / 1e9
    except Exception:
        return 6.0


def pick_batch():
    """Windows decoded at once. Decoding Thai is token-heavy, so a bigger batch is the main speed lever;
    stay small only when memory is tight (e.g. Zoom is still running)."""
    gb = free_gb()
    return 16 if gb > 5 else (8 if gb > 2.5 else 4)


def _decode(asr, audio, extra=None, batch=8):
    """Returns [{t0, t1, text, loop}] in the time of `audio` (seconds from its start)."""
    kw = {"language": "th", "task": "transcribe"}
    kw.update(extra or {})
    out = asr({"raw": audio, "sampling_rate": SR}, chunk_length_s=30, stride_length_s=5, batch_size=batch,
              return_timestamps=True, generate_kwargs=kw)
    res = []
    for c in out.get("chunks") or []:
        ts = c.get("timestamp") or (0, None)
        t0 = float(ts[0] or 0)
        t1 = float(ts[1]) if ts[1] is not None else t0 + 2
        text, loop = collapse_loops((c.get("text") or "").strip())
        res.append({"t0": t0, "t1": t1, "text": text, "loop": loop})
    if not res and (out.get("text") or "").strip():
        text, loop = collapse_loops(out["text"].strip())
        res.append({"t0": 0.0, "t1": len(audio) / SR, "text": text, "loop": loop})
    return res


GAP = 0.5      # seconds of silence kept between regions packed into one block


def pack_block(track, regs):
    """Glue speech regions end to end (silence dropped) so Whisper's 30 s windows are full.
    Returns (audio, mapping) with mapping = [(v0, v1, abs_start)]."""
    import numpy as np
    parts, mapping, v = [], [], 0.0
    gap = np.zeros(int(GAP * SR), dtype="float32")
    for s, e in regs:
        seg = track[int(s * SR): int(e * SR)]
        mapping.append((v, v + len(seg) / SR, s))
        parts += [seg, gap]
        v += len(seg) / SR + GAP
    return np.concatenate(parts) if parts else np.zeros(1, dtype="float32"), mapping


def vmap(mapping, v):
    for v0, v1, a0 in mapping:
        if v < v1 + GAP:
            return a0 + max(0.0, min(v, v1) - v0)
    v0, v1, a0 = mapping[-1]
    return a0 + (v1 - v0)


def transcribe_block(asr, audio, mapping, batch):
    chunks = _decode(asr, audio, None, batch)
    segs = []
    for c in chunks:
        text = c["text"]
        if c["loop"] >= 0.25 and c["t1"] > c["t0"]:       # stuck in a repeat loop → redo just this window
            a, b = max(0.0, c["t0"] - 1.0), min(len(audio) / SR, c["t1"] + 1.0)
            try:
                redo = _decode(asr, audio[int(a * SR): int(b * SR)],
                               {"no_repeat_ngram_size": 4, "repetition_penalty": 1.15}, 1)
                alt = " ".join(r["text"] for r in redo).strip()
                if len(alt) > len(text):
                    text = alt
            except Exception:
                pass
        if text and not is_junk(text):
            segs.append({"t0": vmap(mapping, c["t0"]), "t1": vmap(mapping, c["t1"]), "text": text})
    return segs


def fake_transcribe(track, regions):
    """Test hook (MEETING_FAKE_ASR=1): deterministic segments without any model."""
    segs = []
    for i, (s, e) in enumerate(regions):
        segs.append({"t0": s, "t1": min(e, s + 4), "text": f"{track} ข้อความทดสอบช่วงที่ {i + 1} ประชุม deadline วันศุกร์"})
    return segs


def split_blocks(regs, target=480):
    """Group speech regions into ≈8-minute blocks (cut between regions)."""
    blocks, cur, dur = [], [], 0.0
    for r in regs:
        cur.append(r)
        dur += r[1] - r[0] + GAP
        if dur >= target:
            blocks.append(cur)
            cur, dur = [], 0.0
    if cur:
        blocks.append(cur)
    return blocks


def transcribe_all(tracks, pre=None):
    """tracks: {name: np.ndarray}. Returns {name: [seg]}.
    pre = {name: (cut_seconds, [seg])}: audio before `cut` was already transcribed while recording."""
    fake = os.environ.get("MEETING_FAKE_ASR") == "1"
    pre = pre or {}
    plan = {}
    for k, v in tracks.items():
        cut = pre.get(k, (0.0, []))[0]
        plan[k] = [(max(s, cut), e) for s, e in active_regions(v) if e > cut + 0.3]
    total_audio = sum(e - s for regs in plan.values() for s, e in regs) or 1.0
    has_work = any(plan.values())
    asr, device = (None, "fake") if (fake or not has_work) else (None, "lazy")
    if device == "lazy":
        status("loading", 2, "กำลังโหลดโมเดลถอดเสียง…")
        asr, device = build_asr()
    done_audio, results = 0.0, {}
    batch = pick_batch()
    for name, regs in plan.items():
        segs = list(pre.get(name, (0.0, []))[1])
        for blk in split_blocks(regs):
            try:
                if fake:
                    part = fake_transcribe(name, blk)
                else:
                    audio, mapping = pack_block(tracks[name], blk)
                    part = transcribe_block(asr, audio, mapping, batch)
            except Exception as exc:                      # MPS hiccup → retry once on CPU
                if fake or device == "cpu":
                    raise
                status("loading", 5, f"MPS error ({exc.__class__.__name__}) — ลองใหม่บน CPU")
                import torch
                del asr
                gc.collect()
                os.environ["MEETING_FORCE_CPU"] = "1"
                from transformers import pipeline
                asr = pipeline("automatic-speech-recognition", model=ASR_MODEL, torch_dtype=torch.float32, device="cpu")
                device, batch = "cpu", 4
                audio, mapping = pack_block(tracks[name], blk)
                part = transcribe_block(asr, audio, mapping, batch)
            segs.extend(part)
            done_audio += sum(e - s for s, e in blk)
            status("transcribing", 5 + 75 * done_audio / total_audio,
                   f"ถอดเสียง {WHO[name]} · {fmt_ts(blk[-1][1])}")
        results[name] = segs
    release_asr(asr)
    return results


def release_asr(asr):
    if asr is None:
        return
    del asr
    gc.collect()
    try:
        import torch
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
    except Exception:
        pass


# --------------------------------------------------------------------------- live (while recording)
def caf_layout(path):
    """Parse a CAF header that may still be growing. Returns (data_offset, bytes_per_frame, fmt) or None.
    The data-chunk size in a file that is still being written is unreliable, so only the file length is used."""
    import struct
    with open(path, "rb") as f:
        head = f.read(4096)
    if len(head) < 20 or head[:4] != b"caff":
        return None
    pos, fmt = 8, None
    while pos + 12 <= len(head):
        kind = head[pos:pos + 4]
        size = struct.unpack(">q", head[pos + 4:pos + 12])[0]
        body = pos + 12
        if kind == b"desc" and body + 32 <= len(head):
            rate, _fid, flags, bpp, _fpp, ch, bits = struct.unpack(">d4sIIIII", head[body:body + 32])
            fmt = {"rate": rate, "float": bool(flags & 1), "little": bool(flags & 2), "ch": ch, "bits": bits, "bpp": bpp}
        elif kind == b"data":
            if not fmt or not fmt["bpp"]:
                return None
            return body + 4, fmt["bpp"], fmt
        if size < 0:
            return None
        pos = body + size
    return None


def caf_seconds(path):
    lay = caf_layout(path)
    if not lay:
        return 0.0
    off, bpf, fmt = lay
    return max(0, os.path.getsize(path) - off) // bpf / fmt["rate"]


def read_caf_raw(path, start_s, end_s):
    """Mono float32 samples [start_s, end_s) from a CAF that may still be written."""
    import numpy as np
    lay = caf_layout(path)
    if not lay:
        return np.zeros(0, dtype="float32")
    off, bpf, fmt = lay
    total = max(0, os.path.getsize(path) - off) // bpf
    f0 = int(start_s * fmt["rate"]); f1 = min(total, int(end_s * fmt["rate"]))
    if f1 <= f0:
        return np.zeros(0, dtype="float32")
    with open(path, "rb") as f:
        f.seek(off + f0 * bpf)
        raw = f.read((f1 - f0) * bpf)
    sw = fmt["bits"] // 8
    dt = ("<" if fmt["little"] else ">") + ("f" if fmt["float"] else "i") + str(sw)
    x = np.frombuffer(raw[: (len(raw) // bpf) * bpf], dtype=np.dtype(dt)).astype("float32")
    if not fmt["float"]:
        x = x / float(2 ** (fmt["bits"] - 1))
    if fmt["ch"] > 1:
        x = x.reshape(-1, fmt["ch"]).mean(axis=1)
    if abs(fmt["rate"] - SR) > 1 and len(x):
        n = int(len(x) * SR / fmt["rate"])
        x = np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x).astype("float32")
    return x.astype("float32")


LIVE_CHUNK = float(os.environ.get("MEETING_LIVE_CHUNK", "360"))     # transcribe once this much new audio exists
SECTION_CACHE = None                                               # per session: finished section notes by prompt hash


def _load_json(p, default):
    try:
        return json.loads(pathlib.Path(p).read_text(encoding="utf-8"))
    except Exception:
        return default


def _save_json(p, obj):
    p = pathlib.Path(p)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, p)


def live_round(d, st):
    """One pass over both tracks. Returns True if anything new was transcribed."""
    did, asr = False, None
    for name in ("system", "mic"):
        src = None
        for base in RAW_NAMES[name]:
            if (d / (base + ".caf")).exists():
                src = d / (base + ".caf")
                break
        if src is None:
            continue
        cut = st["done"].get(name, 0.0)
        avail = caf_seconds(src)
        if avail - cut < LIVE_CHUNK + 20 or free_gb() < 3.0:
            continue
        audio = read_caf_raw(src, cut, avail - 15)
        horizon = len(audio) / SR
        regs = active_regions(audio)
        closed = [r for r in regs if r[1] < horizon - 3.0]
        open_ = [r for r in regs if r[1] >= horizon - 3.0]
        new_cut = (open_[0][0] if open_ else horizon - 5.0)
        if closed:
            new_cut = max(new_cut, closed[-1][1])
            if asr is None:
                asr, _dev = build_asr()
            batch = min(pick_batch(), 8)
            segs = st["segs"].setdefault(name, [])
            for blk in split_blocks(closed):
                audio_b, mapping = pack_block(audio, blk)
                for sg in transcribe_block(asr, audio_b, mapping, batch):
                    segs.append({"t0": sg["t0"] + cut, "t1": sg["t1"] + cut, "text": sg["text"]})
        if new_cut > 0:
            st["done"][name] = cut + new_cut
            _save_json(d / "live.json", st)
            did = did or bool(closed)
    release_asr(asr)
    return did


def live_prewarm_notes(d, st, context):
    """With enough free memory, write the detailed notes for sections that are already complete."""
    if free_gb() < 7.0:
        return
    rows = merge_segments({k: list(v) for k, v in st["segs"].items()})
    groups = chunk_rows(rows, SECTION_CHARS)[:-1]            # the last group may still grow
    if not groups:
        return
    cache = _load_json(d / "live-sections.json", {})
    model = pick_model(ensure_ollama(), "auto")
    ctx, gl = section_context(context, load_glossary())
    for g in groups:
        prompt = section_prompt(ctx, gl, g)
        key = hashlib.sha1((model + prompt).encode("utf-8")).hexdigest()
        if key in cache:
            continue
        cache[key] = llm(model, prompt, SYSTEM)
        _save_json(d / "live-sections.json", cache)


def live_loop(d, context):
    st = _load_json(d / "live.json", {"done": {}, "segs": {}})
    st.setdefault("done", {}); st.setdefault("segs", {})
    idle, last_size = 0, -1
    while True:
        try:
            if live_round(d, st):
                try:
                    live_prewarm_notes(d, st, context)
                except Exception as exc:
                    print(f"[live] notes prewarm skipped: {exc}", file=sys.stderr)
        except Exception as exc:
            print(f"[live] round failed: {exc.__class__.__name__}: {exc}", file=sys.stderr)
        size = sum(f.stat().st_size for f in d.glob("*.caf"))
        idle = idle + 1 if size == last_size else 0
        last_size = size
        if idle >= 20:                  # recording ended (or the app died): stop on our own
            return
        time.sleep(30)


# --------------------------------------------------------------------------- merge
def drop_echo(mic, system):
    """Without headphones the mic hears the speakers: drop mic lines that mirror system lines."""
    kept = []
    for m in mic:
        near = [s for s in system if s["t1"] >= m["t0"] - 3 and s["t0"] <= m["t1"] + 3]
        echo = any(difflib.SequenceMatcher(None, m["text"], s["text"]).ratio() > 0.55 for s in near)
        if not echo:
            kept.append(m)
    return kept



# ----------------------------------------------------------------- MBM vocabulary
# Whisper writes English marketing terms phonetically in Thai. These regexes repair the
# most common ones in the transcript; DEFAULT_GLOSSARY also goes to the summariser.
# Extra terms: one per line in ~/Library/Application Support/OverlayLens/meeting-glossary.txt
DEFAULT_GLOSSARY = [
    "Brand Equity", "Brand Positioning", "Brand Identity", "Brand Image", "Brand Awareness",
    "Brand Loyalty", "Brand Architecture", "Customer-Based Brand Equity (CBBE)",
    "Kevin Keller", "Philip Kotler", "David Aaker", "STP", "Segmentation", "Targeting",
    "Positioning", "Marketing Mix (4P)", "SWOT", "Value Proposition", "Customer Journey",
    "Touchpoint", "Insight", "Persona", "Differentiation", "Point of Difference (POD)",
    "Point of Parity (POP)", "Brand Resonance", "IMC", "KPI", "ROI", "CRM",
]
_EQ = r"(?:equity|อีควิตี้|เอควิตี้|อิควิตี้|อีควิที่|เอควิที่|เอ็กควิตี้)"
_BR = r"(?:แบรนด์|แบรน|แรนด์|แรน(?!ด)|เบรนด์)"
FIXES = [
    (r"ร้าน\s*" + _EQ, "Brand Equity"),
    (_BR + r"\s*" + _EQ, "Brand Equity"),
    (r"(?:โพซิชั่นนิ่ง|โพสิชั่นนิ่ง|โพซิชันนิ่ง|โพสิชันนิ่ง|โพซิชั่นนิง)", "Positioning"),
    (r"(?:เซกเมนเทชัน|เซ็กเมนเตชั่น|เซกเมนเตชั่น|เซ็กเมนเทชัน)", "Segmentation"),
    (r"(?:ทาร์เก็ตติ้ง|ทาเก็ตติ้ง|ทาร์เก็ตติง)", "Targeting"),
    (r"(?:เอสทีพี|เอสที พี)", "STP"),
    (r"(?:เอสดับเบิลยูโอที|เอสดับบลิวโอที)", "SWOT"),
    (r"มาร์เก็ตติ้ง\s*มิกซ์", "Marketing Mix"),
    (r"เควิน\s*เค[ลน]เลอร์", "Kevin Keller"),
    (r"(?:ฟิลิป|ฟิลลิป)\s*คอตเลอร์", "Philip Kotler"),
    (_BR + r"(?![\u0E00-\u0E7F])", "แบรนด์"),
]


def apply_fixes(text):
    for pat, rep in FIXES:
        if rep.isascii():                      # keep a space between Thai text and the English term
            rep = f" {rep} "
        text = re.sub(pat, rep, text, flags=re.I)
    return re.sub(r" {2,}", " ", text).strip()


def merge_segments(results):
    mic = drop_echo(results.get("mic", []), results.get("system", []))
    rows = [dict(s, who=WHO["system"]) for s in results.get("system", [])]
    rows += [dict(s, who=WHO["mic"]) for s in mic]
    for r in rows:
        r["text"] = apply_fixes(r["text"])
    rows.sort(key=lambda r: r["t0"])
    out = []
    for r in rows:
        if out and out[-1]["who"] == r["who"] and r["t0"] - out[-1]["t1"] < 2.0 and len(out[-1]["text"]) < 400:
            out[-1]["text"] += " " + r["text"]
            out[-1]["t1"] = r["t1"]
        elif out and out[-1]["who"] == r["who"] and out[-1]["text"] == r["text"]:
            continue
        else:
            out.append(dict(r))
    return out


def write_transcript(rows, path, title, meta, duration):
    lines = [f"# Transcript — {title}", ""]
    started = meta.get("startedAt", "")
    lines.append(f"> บันทึกเมื่อ {started} · ความยาว {fmt_ts(duration)} · ประชุม = เสียงจากแอปประชุม, ผม = ไมค์")
    lines.append("")
    for r in rows:
        lines.append(f"[{fmt_ts(r['t0'])}] **{r['who']}:** {r['text']}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def read_transcript(path):
    rows = []
    pat = re.compile(r"^\[(\d\d:\d\d:\d\d)\] \*\*(.+?):\*\* (.*)$")
    for line in path.read_text(encoding="utf-8").splitlines():
        m = pat.match(line)
        if m:
            rows.append({"t0": parse_ts(m.group(1)), "t1": parse_ts(m.group(1)), "who": m.group(2), "text": m.group(3)})
    return rows


# --------------------------------------------------------------------------- LLM
def http_json(method, url, payload=None, timeout=1800):
    import requests
    r = requests.request(method, url, json=payload, timeout=timeout)
    return r


def ensure_ollama():
    import requests
    for attempt in range(2):
        try:
            return requests.get(f"{OLLAMA}/api/tags", timeout=3).json()
        except Exception:
            if attempt == 0:
                subprocess.run(["open", "-a", "Ollama"], check=False)
                for _ in range(40):
                    time.sleep(1)
                    try:
                        return requests.get(f"{OLLAMA}/api/tags", timeout=2).json()
                    except Exception:
                        pass
    raise RuntimeError("ต่อ Ollama ไม่ได้ — เปิดแอป Ollama แล้วลองใหม่")


def pick_model(tags, wanted):
    names = [m["name"] for m in tags.get("models", [])]
    if wanted and wanted != "auto":
        if wanted in names:
            return wanted
        raise RuntimeError(f"ไม่พบโมเดล {wanted} ใน Ollama (มี: {', '.join(names)})")
    for p in PREFERRED_LLMS:
        for n in names:
            if n == p or n.startswith(p + ":") or n.startswith(p):
                return n
    usable = [n for n in names if "embed" not in n]
    if not usable:
        raise RuntimeError("Ollama ยังไม่มีโมเดลสำหรับสรุป — รัน: ollama pull qwen3.5:9b")
    return usable[0]


def llm(model, prompt, system=None):
    body = {"model": model, "stream": False, "think": False,
            "messages": ([{"role": "system", "content": system}] if system else []) + [{"role": "user", "content": prompt}],
            "options": {"temperature": 0.2, "num_ctx": 16384}}
    r = http_json("POST", f"{OLLAMA}/api/chat", body)
    if r.status_code == 400 and "think" in r.text.lower():
        body.pop("think")
        r = http_json("POST", f"{OLLAMA}/api/chat", body)
    if r.status_code != 200:
        raise RuntimeError(f"Ollama {r.status_code}: {r.text[:200]}")
    text = r.json()["message"]["content"].strip()
    return re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()


SYSTEM = ("คุณเป็นผู้ช่วยจดบันทึกการประชุม/คาบเรียนออนไลน์ภาษาไทย ข้อความมาจากระบบถอดเสียงอัตโนมัติ "
          "จึงอาจมีคำผิดหรือคำอังกฤษที่สะกดเป็นไทย ให้เดาคำที่ถูกต้องจากบริบท ห้ามแต่งข้อมูลที่ไม่มีใน transcript "
          "เขียนเป็นภาษาไทย คงศัพท์เทคนิค/ธุรกิจเป็นภาษาอังกฤษ")

SECTION_PROMPT = """{ctx}ด้านล่างคือ transcript ช่วง {a}–{b} ของการประชุม/คาบเรียน ให้เขียน "โน้ตเนื้อหาละเอียด" ของช่วงนี้
เป้าหมาย: คนที่ไม่ได้เข้าเรียนอ่านแล้วต้องได้เนื้อหาครบ ไม่ใช่แค่หัวข้อ — ห้ามย่อจนเหลือแต่ภาพรวม
กติกา:
- เรียงตามลำดับที่พูด แบ่งเป็นหัวข้อย่อย (### ชื่อหัวข้อ) ตามเรื่องที่ผู้พูดเปลี่ยน
- ทุก concept/ทฤษฎี/framework: เขียนคำอธิบายตามที่ผู้พูดอธิบายจริง (2–4 ประโยค) ไม่ใช่แค่ชื่อ
- **ตัวอย่าง / case / แบรนด์ / บริษัท / สินค้า / ตัวเลข / เหตุการณ์ ที่ผู้พูดยกมา ต้องใส่ครบทุกอัน** ขึ้นต้นบรรทัดด้วย "ตัวอย่าง:" พร้อมบอกว่าใช้อธิบายเรื่องอะไร
- คำถาม-คำตอบกับผู้เรียน, งานที่สั่ง, deadline, สิ่งที่ผู้พูดเน้นว่าสำคัญ/ออกสอบ ให้ใส่ (อ้างคำพูดสั้นๆ ได้)
- ข้ามเฉพาะเรื่องไม่เกี่ยว (ทักทาย ปัญหาเทคนิค ได้ยินไหม)
- เขียนเป็น bullet ที่มีข้อมูล ยาวเท่าที่จำเป็น (ประมาณ 15–30 บรรทัดต่อช่วง) ห้ามแต่งข้อมูลที่ไม่มีใน transcript
- คำที่ถอดผิด ให้แก้เป็นคำที่ถูกต้องจากบริบท

{glossary}TRANSCRIPT:
{text}"""

FINAL_PROMPT = """{ctx}ด้านล่างคือโน้ตเนื้อหาละเอียดของการประชุม/คาบเรียนเดียวกัน (ตัดทอนมาบางส่วน) ให้เขียน "ภาพรวม" ไว้ด้านบนของโน้ต
ใช้โครงสร้าง Markdown นี้เป๊ะ (หัวข้อที่ไม่มีข้อมูลให้เขียนว่า "ไม่พบใน transcript") ใช้เฉพาะข้อมูลที่อยู่ในโน้ตด้านล่าง:

## สรุปสั้น
(3–5 บรรทัด)
## การตัดสินใจ / ข้อสรุป
## Action items
(รูปแบบ: ใคร — ทำอะไร — เมื่อไหร่)
## 📌 งาน / Deadline / "ออกสอบ"
## Key concepts & คำศัพท์
- **term**: นิยามสั้น 1 บรรทัด
## คำถามค้าง / จุดที่ transcript ไม่ชัด

NOTES:
{text}"""


def chunk_rows(rows, limit):
    groups, cur, size = [], [], 0
    for r in rows:
        line = f"[{fmt_ts(r['t0'])}] {r['who']}: {r['text']}"
        if size + len(line) > limit and cur:
            groups.append(cur)
            cur, size = [], 0
        cur.append(line)
        size += len(line) + 1
    if cur:
        groups.append(cur)
    return groups


def load_glossary():
    gl_path = pathlib.Path.home() / "Library/Application Support/OverlayLens/meeting-glossary.txt"
    extra = [x.strip() for x in gl_path.read_text(encoding="utf-8").splitlines() if x.strip()] if gl_path.exists() else []
    return ", ".join(DEFAULT_GLOSSARY + extra)


def section_context(context, glossary):
    ctx = f"บริบท: {context}\n" if context else ""
    gl = (f"รายการคำสะกดที่ถูกต้อง (ใช้เฉพาะแก้การสะกดคำที่ปรากฏใน transcript เท่านั้น "
          f"ห้ามนำคำหรือเนื้อหาจากรายการนี้มาใส่ถ้า transcript ไม่ได้พูดถึง): {glossary}\n\n") if glossary else ""
    return ctx, gl


def section_prompt(ctx, gl, g):
    a, b = g[0][1:9], g[-1][1:9]
    return SECTION_PROMPT.format(ctx=ctx, glossary=gl, a=a, b=b, text="\n".join(g))


def summarize(rows, model, context, glossary):
    ctx, gl = section_context(context, glossary)
    groups = chunk_rows(rows, SECTION_CHARS)
    cache = _load_json(SECTION_CACHE, {}) if SECTION_CACHE else {}
    parts, hits = [], 0
    for i, g in enumerate(groups, 1):
        status("summarizing", 82 + 13 * i / len(groups), f"จดเนื้อหาช่วง {i}/{len(groups)}")
        a, b = g[0][1:9], g[-1][1:9]
        prompt = section_prompt(ctx, gl, g)
        key = hashlib.sha1((model + prompt).encode("utf-8")).hexdigest()
        if key in cache:
            hits += 1
            text = cache[key]
        else:
            text = llm(model, prompt, SYSTEM)
        parts.append(f"## ช่วง {a}–{b}\n" + text)
    status("summarizing", 97, f"เขียนภาพรวม… (ใช้โน้ตที่เตรียมไว้ระหว่างอัด {hits}/{len(groups)} ช่วง)")
    each = max(900, OVERVIEW_BUDGET // len(parts))
    trimmed = "\n\n".join(p[:each] for p in parts)
    overview = llm(model, FINAL_PROMPT.format(ctx=ctx, text=trimmed), SYSTEM)
    return overview, "\n\n".join(parts)


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session_dir")
    ap.add_argument("--title", default="")
    ap.add_argument("--context", default="")
    ap.add_argument("--llm", default="auto")
    ap.add_argument("--skip-summary", action="store_true")
    ap.add_argument("--summarize-only", action="store_true")
    ap.add_argument("--compress-only", action="store_true")
    ap.add_argument("--live", action="store_true")
    a = ap.parse_args()

    d = pathlib.Path(a.session_dir).expanduser()
    meta_path = d / "meta.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else {}
    title = a.title or meta.get("title") or d.name
    context = a.context or meta.get("context", "")
    global SECTION_CACHE
    SECTION_CACHE = d / "live-sections.json"
    if a.live:
        live_loop(d, context)
        return
    if a.compress_only:
        print("compressed:", compress_audio(d) or "nothing")
        return
    tpath = d / "ข้อความถอดเสียง.md"
    if a.summarize_only and not tpath.exists() and (d / "transcript.md").exists():
        tpath = d / "transcript.md"

    if a.summarize_only:
        rows = read_transcript(tpath)
        duration = rows[-1]["t0"] if rows else 0
    else:
        tracks = {}
        for name in ("system", "mic"):
            p = find_audio(d, name)
            if p and p.stat().st_size > 8192:
                tracks[name] = load_track(p)
        if not tracks:
            raise RuntimeError("ไม่พบไฟล์เสียงที่บันทึก (เสียงประชุม.caf / เสียงไมค์.caf ว่างเปล่า)")
        duration = max(len(v) for v in tracks.values()) / SR
        live = _load_json(d / "live.json", {"done": {}, "segs": {}})
        pre = {k: (float(live["done"].get(k, 0.0)), live["segs"].get(k, [])) for k in tracks if live["done"].get(k)}
        if pre:
            status("loading", 2, "ใช้ข้อความที่ถอดไว้ระหว่างอัดแล้ว " + ", ".join(f"{WHO[k]} {fmt_ts(v[0])}" for k, v in pre.items()))
        results = transcribe_all(tracks, pre)
        rows = merge_segments(results)
        write_transcript(rows, tpath, title, meta, duration)
        status("transcribed", 82, f"ถอดเสียงเสร็จ · {len(rows)} ช่วงข้อความ")

    if not rows:
        raise RuntimeError("ไม่พบเสียงพูดในไฟล์ — เช็คว่าเสียงประชุมออกลำโพงจริงและเลือกแอปถูกตัว")
    if a.skip_summary:
        emit("DONE", notes="", transcript=str(tpath))
        return

    status("summarizing", 84, "กำลังเตรียมโมเดลสรุป…")
    tags = ensure_ollama()
    model = pick_model(tags, a.llm)
    glossary = load_glossary()
    final, parts = summarize(rows, model, context, glossary)

    header = (f"# {title}\n\n> {meta.get('startedAt', '')} · ความยาว {fmt_ts(duration)} · "
              f"สรุปโดย {model} (local) · [ข้อความถอดเสียงเต็ม]({tpath.name})\n\n")
    body = final + "\n"
    if parts:
        body += "\n---\n\n# เนื้อหาละเอียดตามลำดับคาบ\n\n" + parts + "\n"
    npath = d / "สรุป.md"
    npath.write_text(header + body, encoding="utf-8")
    for junk in ("live.json", "live-sections.json"):
        (d / junk).unlink(missing_ok=True)
    try:
        compress_audio(d)
    except Exception:
        pass
    status("done", 100, "เสร็จแล้ว")
    emit("DONE", notes=str(npath), transcript=str(tpath))


if __name__ == "__main__":
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    try:
        main()
    except Exception as exc:      # the app shows this message
        emit("ERROR", msg=f"{exc.__class__.__name__}: {exc}")
        sys.exit(1)
