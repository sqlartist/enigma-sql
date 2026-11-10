#!/usr/bin/env python3
"""Carry the PostGIS exploded Enigma to the 3D viewer.

  python tools/export_exploded.py [psql connection args]

Everything in the file was computed by the database (enigma_exploded.sql):
every solid as triangles, the order the machine comes apart in and how far
each part goes out in the exploded view. This only moves it from
PostgreSQL to viewer/enigma_data.js, using psql (default database: enigma).
"""
import json, subprocess, sys
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "viewer" / "enigma_data.js"
args = sys.argv[1:] or ["-d", "enigma"]
data = subprocess.run(["psql", *args, "-At", "-c", "SELECT enigma.export_json()"],
                      check=True, capture_output=True, text=True).stdout.strip()
OUT.parent.mkdir(exist_ok=True)
OUT.write_text("window.ENIGMA = " + data + ";\n", encoding="utf-8")
d = json.loads(data)
tri = sum(len(pc["pos"]) // 9 for p in d["parts"] for pc in p["pieces"])
print(f"{len(d['parts'])} parts, {tri:,} triangles -> {OUT} ({OUT.stat().st_size / 1e6:.1f} MB)")
