#!/usr/bin/env python3
"""N0 spike: list candidate gold sessions for each question by its probe regex.

A human (or the experimenter) reviews the candidates and writes the final gold list into
questions.json before any arm is built. Prints session ids, source, title and match counts.
"""

import json
import os
import re
import sqlite3
import sys
from collections import defaultdict

D = os.environ.get("N0_DIR", os.path.expanduser("~/.local/share/omarchy-memstore/spike-n0"))
c = sqlite3.connect(os.path.join(D, "n0.db"))
qs = json.load(open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(D, "questions.draft.json")))
leaves = c.execute("select session, role, text from leaves").fetchall()
titles = {r[0]: (r[1], r[2] or r[3] or "") for r in c.execute("select id, source, title, first_user from sessions")}
for q in qs:
    rx = re.compile(q["probe"], re.I)
    hits = defaultdict(lambda: defaultdict(int))
    for sess, role, text in leaves:
        if rx.search(text):
            hits[sess][role] += 1
    print(f"\n{q['id']}: {q['q']}  /{q['probe']}/")
    for sess, roles in sorted(hits.items(), key=lambda kv: -sum(kv[1].values()))[:12]:
        src, title = titles.get(sess, ("?", ""))
        print(f"   {sum(roles.values()):4d} {dict(roles)} {sess[:60]} | {title[:50]}")
