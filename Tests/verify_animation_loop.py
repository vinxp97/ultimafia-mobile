#!/usr/bin/env python3
"""AnimatedWebPView must drive its frame loop from load()'s return value, not from @State it
just wrote (unattached state reads back empty -> GIF banners/bio images froze on frame 0)."""
import re, sys
src = open("Ultimafia/Features/Game/PlayerChrome.swift").read()
task = src[src.index('.task(id: "\\(url.absoluteString)#\\(revision)#\\(freeze)")'):src.index("private func resizableImage")]
ok = True
def check(cond, msg):
    global ok
    print(("PASS: " if cond else "FAIL: ") + msg); ok &= cond
check("let loaded = await load()" in task, "loop uses load()'s result")
check(not re.search(r"\bframes\.count\b", task), "loop never reads the frames @State")
check("loaded.images.count > 1" in task, "single-frame images (PNG/JPEG) don't start a loop")
check("max(delay, 0.04)" in task, "frame delay floor kept")
sys.exit(0 if ok else 1)
