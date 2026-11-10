#!/usr/bin/env python3
"""Builds the review package: python3 -I build_package.py <screenshots-dir> <out-dir>

Reads screens.json (the manifest), copies every PNG to <out>/images/<ID>-<base>-<light|dark>-<en|de>.png, writes
<out>/index.html (self-contained contact sheet with comment boxes) and <out>/OVERVIEW.md (OVERVIEW.md with the table
of contents filled in).
"""
import html, json, re, shutil, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
shots, out = Path(sys.argv[1]), Path(sys.argv[2])
manifest = json.loads((HERE / "screens.json").read_text())
screens = manifest["screens"]
ids = [s["id"] for s in screens]
assert len(ids) == len(set(ids)), "duplicate screen IDs"
assert all(re.fullmatch(r"S-\d{1,2}\.\d{2}", i) for i in ids), "bad ID"

(out / "images").mkdir(parents=True, exist_ok=True)
for old in (out / "images").glob("*.png"):
    old.unlink()
variants = [("light", "en", ""), ("dark", "en", ""), ("light", "de", "-de"), ("dark", "de", "-de")]
count, missing = 0, []
for s in screens:
    s["images"] = {}
    for mode, lang, suffix in variants:
        src = shots / f"{s['base']}-{mode}{suffix}.png"
        name = f"{s['id']}-{s['base']}-{mode}-{lang}.png"
        if src.exists():
            shutil.copyfile(src, out / "images" / name)
            s["images"][f"{mode}-{lang}"] = "images/" + name
            count += 1
        else:
            missing.append(str(src.name))
if missing:
    print("MISSING:", missing, file=sys.stderr)
    sys.exit(1)

toc_md = ["| ID | Screen | When it appears |", "|---|---|---|"]
for sec, name in manifest["sections"].items():
    toc_md.append(f"| **{sec}** | **{name}** | |")
    for s in screens:
        if str(s["section"]) == sec:
            toc_md.append(f"| {s['id']} | {s['title']} | {s['when']} |")
ov = (HERE / "OVERVIEW.md").read_text().replace("<!-- TOC -->", "\n".join(toc_md))
(out / "OVERVIEW.md").write_text(ov)

stamp_file = shots / "render-stamp.json"
stamp = json.loads(stamp_file.read_text()) if stamp_file.exists() else None
data = json.dumps({"sections": manifest["sections"], "screens": screens, "stamp": stamp}, ensure_ascii=False).replace("</", "<\\/")
page = (HERE / "index.template.html").read_text().replace("/*__DATA__*/null", data)
(out / "index.html").write_text(page)
print(f"{len(screens)} screens, {count} images -> {out}")
