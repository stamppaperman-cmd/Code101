#!/bin/zsh
# Build a Thai speech fixture with an exact reference transcript.
#
# Ground truth for Thai ASR normally costs hours of hand-transcription, which is why
# this project has never had a single error-rate number — only coverage, which a
# hallucinating model can score 100% on. macOS ships a Thai voice (Kanya), so the
# reference can be the *input* instead: whatever is spoken is known exactly, for any
# length, reproducibly, at no cost.
#
# What this fixture is for: ranking configurations against each other. It is NOT a
# measure of real-world accuracy — synthesised speech is cleaner than any interview,
# has one speaker, no crosstalk and no room. Expect the absolute error rate to be
# flattering. Relative order between two configs is the thing it is honest about.
#
# Numbers are spelled as Thai words on purpose. `say` reads "๓๑" and "31" aloud as
# words, so a digit in the reference would be scored as an error the moment Whisper
# writes it back as a word — measuring transcription of a convention, not of speech.
#
#   ./tools/make-fixture.sh [minutes]     default 5
set -e -o pipefail
cd "$(dirname "$0")/.."

MINUTES=${1:-5}
VOICE=Kanya
OUT_DIR=testdata
WAV="$OUT_DIR/fixture-th.wav"
REF="$OUT_DIR/fixture-th.txt"
mkdir -p "$OUT_DIR"

if ! say -v '?' | grep -q "^$VOICE"; then
  echo "ไม่พบเสียง $VOICE ในเครื่องนี้ — ติดตั้งเสียงไทยจาก System Settings > Accessibility > Spoken Content"
  exit 1
fi

# Ten distinct passages. Each one carries something that has actually broken before:
# a name to attribute, a word Whisper misspelled, a weekday the cleanup model rewrote,
# a spoken number it changed, and an introduction for the speaker namer to read.
build_script() {
  local rounds=$1
  : > "$REF"
  for round in $(seq 1 "$rounds"); do
    cat >> "$REF" <<'TXT'
สวัสดีครับ ผมชื่อสมชาย เป็นผู้จัดการฝ่ายการตลาดของบริษัทเทอร์เทิล
วันนี้เราจะมาสรุปผลประกอบการของไตรมาสที่สองกันก่อนนะครับ
สาขาภูเก็ตทำยอดขายได้ดีกว่าที่ตั้งเป้าไว้ประมาณสิบห้าเปอร์เซ็นต์
แคมเปญที่เราปล่อยไปเมื่อเดือนที่แล้วได้ผลตอบรับดีเกินคาดมากครับ
ลูกค้าหลักของเราตอนนี้อายุเฉลี่ยสามสิบเอ็ดปี ซึ่งอ่อนกว่าปีที่แล้ว
เราต้องส่งรายงานฉบับเต็มให้ทีมบัญชีภายในวันศุกร์นี้นะครับ
ส่วนการประชุมกับพาร์ตเนอร์เลื่อนไปเป็นวันจันทร์หน้าแทนแล้วครับ
พี่แต่งกวาช่วยดูเรื่องงบประมาณของไตรมาสถัดไปให้หน่อยได้ไหมครับ
ผมคิดว่าเราควรเพิ่มงบอีกสองแสนบาทสำหรับช่องทางออนไลน์โดยเฉพาะ
ถ้าไม่มีใครสงสัยอะไรเพิ่มเติม ผมขอจบการประชุมไว้เพียงเท่านี้ครับ
TXT
    # A spoken index keeps every round different. Ten identical rounds would be a
    # loop, and the repetition detector would be right to flag the fixture itself.
    echo "จบรอบที่ $round ครับ ขอเริ่มหัวข้อถัดไปเลยนะครับ" >> "$REF"
  done
}

duration_of() {
  afinfo "$1" | awk -F': ' '/estimated duration/ {print int($2)}'
}

# One round to calibrate, then the real build. `say` speaks at its own pace and the
# rate differs by voice and OS version, so the round count is measured, not assumed.
echo "กำลังวัดความเร็วเสียง $VOICE …"
build_script 1
say -v "$VOICE" -o "$WAV" --data-format=LEF32@16000 -f "$REF"
PER_ROUND=$(duration_of "$WAV")
[[ "$PER_ROUND" -gt 0 ]] || { echo "วัดความยาวไม่ได้"; exit 1; }

ROUNDS=$(( (MINUTES * 60 + PER_ROUND - 1) / PER_ROUND ))
[[ "$ROUNDS" -lt 1 ]] && ROUNDS=1

echo "หนึ่งรอบ = ${PER_ROUND}s → ใช้ $ROUNDS รอบเพื่อให้ได้ราว $MINUTES นาที"
build_script "$ROUNDS"
say -v "$VOICE" -o "$WAV" --data-format=LEF32@16000 -f "$REF"

TOTAL=$(duration_of "$WAV")
CHARS=$(python3 -c "import sys;print(len(open(sys.argv[1],encoding='utf-8').read().replace(chr(10),'').replace(' ','')))" "$REF")

echo
echo "เสียง     $WAV  (${TOTAL}s, 16 kHz mono Float32 — ตรงกับที่ AudioDecoder ต้องการอยู่แล้ว)"
echo "เฉลย     $REF  ($CHARS ตัวอักษร)"
echo
# Four workers with 30-second VAD chunks need more than four chunks before batching
# shows up at all; below two minutes the parallelism figure measures nothing.
if [[ "$TOTAL" -lt 240 ]]; then
  echo "หมายเหตุ: สั้นกว่า 4 นาที — จะเห็นผลของ concurrentWorkerCount ไม่ชัด"
fi
