#!/usr/bin/env python3
"""เพิ่มกฎ "ไม่ต้องถาม" ระดับเครื่อง ให้คำสั่งอ่านอย่างเดียวของ Claude Code

ทำไมต้องรันเอง: Claude Code ห้าม AI แก้ไฟล์สิทธิ์ของตัวเอง (self-modification)
จึงต้องเป็นมือผู้ใช้สั่งรัน สคริปต์นี้แตะแค่ permissions.allow ใน
~/.claude/settings.json ไม่แก้ค่าอื่น และสำรองไฟล์เดิมไว้ก่อนทุกครั้ง

    python3 Tools/allow-readonly.py           # เพิ่มกฎ
    python3 Tools/allow-readonly.py --list    # ดูกฎที่มีอยู่
    python3 Tools/allow-readonly.py --undo    # เอากฎชุดนี้ออก
"""

import json
import os
import shutil
import sys
from datetime import datetime

SETTINGS = os.path.expanduser("~/.claude/settings.json")

# คำสั่งอ่านอย่างเดียว: ดูไฟล์ ค้นหา ดูสถานะเครื่อง และ git ที่ไม่เปลี่ยนอะไร
READ_ONLY = [
    # ดูไฟล์และโฟลเดอร์
    "Bash(ls:*)", "Bash(cat:*)", "Bash(head:*)", "Bash(tail:*)", "Bash(wc:*)",
    "Bash(file:*)", "Bash(stat:*)", "Bash(du:*)", "Bash(df:*)", "Bash(tree:*)",
    "Bash(realpath:*)", "Bash(basename:*)", "Bash(dirname:*)", "Bash(readlink:*)",
    # ค้นหาและอ่านเนื้อหา
    # find และ awk ไม่อยู่ในชุดนี้: find มี -delete กับ -exec และ awk เขียนไฟล์
    # เองได้ด้วย print > "ไฟล์" กับ system() กฎ Bash(...:*) แยกสองอย่างนั้นออก
    # จากการใช้อ่านเฉย ๆ ไม่ได้ จึงปล่อยให้ถามตามปกติ (ค้นไฟล์ใช้ rg แทนได้)
    "Bash(grep:*)", "Bash(egrep:*)", "Bash(rg:*)", "Bash(sed -n:*)",
    "Bash(sort:*)", "Bash(uniq:*)", "Bash(cut:*)", "Bash(tr:*)",
    "Bash(diff:*)", "Bash(jq:*)", "Bash(plutil -p:*)",
    # สถานะเครื่อง
    "Bash(pgrep:*)", "Bash(ps:*)", "Bash(pmset -g:*)", "Bash(ioreg:*)",
    "Bash(sw_vers:*)", "Bash(uname:*)", "Bash(whoami)", "Bash(sysctl -n:*)",
    "Bash(defaults read:*)", "Bash(which:*)", "Bash(command -v:*)",
    "Bash(date:*)", "Bash(echo:*)", "Bash(printf:*)", "Bash(true)",
    "Bash(md5:*)", "Bash(md5sum:*)", "Bash(shasum:*)",
    # git ที่อ่านอย่างเดียว
    "Bash(git status:*)", "Bash(git log:*)", "Bash(git diff:*)", "Bash(git show:*)",
    "Bash(git branch:*)", "Bash(git remote -v)", "Bash(git rev-parse:*)",
    "Bash(git blame:*)", "Bash(git ls-files:*)", "Bash(git stash list)",
]


def load():
    with open(SETTINGS, encoding="utf-8") as f:
        return json.load(f)


def save(data):
    stamp = datetime.now().strftime("%Y%m%d%H%M%S")
    shutil.copy2(SETTINGS, f"{SETTINGS}.bak-perm-{stamp}")
    with open(SETTINGS, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    return f"{SETTINGS}.bak-perm-{stamp}"


def main():
    if not os.path.exists(SETTINGS):
        sys.exit(f"ไม่พบไฟล์ {SETTINGS}")

    data = load()
    allow = data.setdefault("permissions", {}).setdefault("allow", [])

    if "--list" in sys.argv:
        print(f"กฎที่มีอยู่ {len(allow)} ข้อ:")
        for rule in allow:
            print(" ", rule)
        return

    if "--undo" in sys.argv:
        keep = [r for r in allow if r not in READ_ONLY]
        removed = len(allow) - len(keep)
        if not removed:
            print("ไม่มีกฎชุดนี้อยู่ ไม่ต้องเอาออก")
            return
        data["permissions"]["allow"] = keep
        backup = save(data)
        print(f"เอาออกแล้ว {removed} ข้อ เหลือ {len(keep)} ข้อ")
        print(f"สำรองไฟล์เดิมไว้ที่ {backup}")
        return

    added = [r for r in READ_ONLY if r not in allow]
    if not added:
        print(f"มีกฎชุดนี้ครบแล้ว ({len(allow)} ข้อ) ไม่ต้องเพิ่ม")
        return

    allow.extend(added)
    backup = save(data)
    print(f"เพิ่มกฎใหม่ {len(added)} ข้อ รวมทั้งหมด {len(allow)} ข้อ")
    print(f"สำรองไฟล์เดิมไว้ที่ {backup}")
    print("กฎมีผลกับแชทที่เปิดใหม่ แชทที่เปิดอยู่แล้วอาจยังถามเหมือนเดิม")


if __name__ == "__main__":
    main()
