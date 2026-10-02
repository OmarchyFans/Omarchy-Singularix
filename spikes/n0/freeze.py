#!/usr/bin/env python3
"""N0 spike: resolve each question's gold spec to explicit session ids and freeze the set.

Gold spec per question: "gold" (session id prefixes), optional "commit_rx" (regex over commit
subjects) and "commit_repo" (every commit in that repo). Writes questions.json (private) and
prints its sha256 so the set can't be changed after the arms are built.
"""

import hashlib
import json
import os
import re
import sqlite3

D = os.environ.get("N0_DIR", os.path.expanduser("~/.local/share/omarchy-memstore/spike-n0"))
c = sqlite3.connect(os.path.join(D, "n0.db"))
import sys  # noqa: E402

SPEC, OUTF = (sys.argv[1:3] + ["questions.spec.json", "questions.json"][len(sys.argv[1:3]):])[:2]
spec = json.load(open(os.path.join(D, SPEC)))
commits = c.execute("select id, title from sessions where source=?", ("g" + "it",)).fetchall()
ids = [r[0] for r in c.execute("select id from sessions")]
out = []
for q in spec:
    gold = set()
    for p in q.get("gold", []):
        m = [i for i in ids if i.startswith(p)]
        assert m, f"{q['id']}: no session for {p}"
        gold.update(m)
    if q.get("commit_rx"):
        rx = re.compile(q["commit_rx"], re.I)
        gold.update(i for i, t in commits if rx.search(t or ""))
    if q.get("commit_repo"):
        gold.update(i for i, _ in commits if i.split(":")[1] == q["commit_repo"])
    out.append({"id": q["id"], "kind": q["kind"], "dev": bool(q.get("dev")), "q": q["q"], "gold": sorted(gold)})
blob = json.dumps(out, indent=1, sort_keys=True)
open(os.path.join(D, OUTF), "w").write(blob)
os.chmod(os.path.join(D, OUTF), 0o600)
print(json.dumps({"questions": len(out), "dev": sum(q["dev"] for q in out),
                  "gold_sizes": {q["id"]: len(q["gold"]) for q in out},
                  "sha256": hashlib.sha256(blob.encode()).hexdigest()}))
