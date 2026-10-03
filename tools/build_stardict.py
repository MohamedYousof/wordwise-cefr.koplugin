#!/usr/bin/env python3
"""Build the two StarDict dictionaries this fork can fall back on.

  freedict  FreeDict eng-ara (dictd release, GPL) -> English-Arabic folder
  wordnet   Open English WordNet json release (CC BY 4.0) -> English folder

Both write plain (uncompressed) StarDict: .ifo + .idx + .dict. sdcv reads
those as-is, so the outputs drop straight into koreader/data/dict/ and then
show up in the plugin's dictionary picker like any installed dictionary.

Usage:
  python3 build_stardict.py freedict <eng-ara.dict.dz> <eng-ara.index> --out <dir>
  python3 build_stardict.py wordnet <oewn-json-dir> --out <dir>
"""
import argparse
import base64
import gzip
import json
import struct
import sys
from pathlib import Path


def write_stardict(out_dir, basename, bookname, description, entries):
    """entries: list of (word, article_text); writes basename.{ifo,idx,dict}."""
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    entries = sorted(entries, key=lambda e: (e[0].lower(), e[0]))

    dict_path = out / f"{basename}.dict"
    idx = bytearray()
    with dict_path.open("wb") as f:
        for word, text in entries:
            data = text.encode("utf-8")
            idx += word.encode("utf-8") + b"\0" + struct.pack(">II", f.tell(), len(data))
            f.write(data)

    ifo = (
        "StarDict's dict ifo file\n"
        "version=2.4.2\n"
        f"wordcount={len(entries)}\n"
        f"idxfilesize={len(idx)}\n"
        f"bookname={bookname}\n"
        "sametypesequence=m\n"
        f"description={description}\n"
    )
    (out / f"{basename}.ifo").write_text(ifo, encoding="utf-8")
    (out / f"{basename}.idx").write_bytes(idx)
    print(f"{out}/{basename}: {len(entries)} entries")


def cmd_freedict(args):
    b64i = lambda b: int.from_bytes(base64.b64decode(b + b"=" * (-len(b) % 4)), "big")
    buf = gzip.open(args.dict_dz, "rb").read()

    # dictd groups alphabetically adjacent headwords into one shared article,
    # each line a headword with its translation on the next line. The index
    # points every headword at its article; pairing by position instead of by
    # name misaligned whenever an article carried an extra line, and the
    # mispairs were real ("commiserate" -> Arabic for "inheritance"). So look
    # each headword up as a line and take its own next line, or skip it.
    words_by_offset = {}
    for line in open(args.index, "rb"):
        parts = line.rstrip(b"\n").split(b"\t")
        if len(parts) != 3 or parts[0].startswith(b"00database"):
            continue  # dictd's own metadata articles
        words_by_offset.setdefault(b64i(parts[1]), []).append(
            parts[0].decode("utf-8", "replace"))
    stops = sorted(words_by_offset) + [len(buf)]

    def is_arabic(text):
        return any("\u0600" <= ch <= "\u06ff" for ch in text)

    def clean_translation(text):
        # FreeDict loves the definite article; a hint wants the bare word.
        # Keep at least three characters after the strip ("ال" alone is not
        # a translation of anything).
        if text.startswith("ال") and len(text) >= 5:
            text = text[2:]
        return text.strip()

    entries = {}
    for start in sorted(words_by_offset):
        lines = [ln.strip() for ln in
                 buf[start:stops[stops.index(start) + 1]]
                 .decode("utf-8", "replace").split("\n") if ln.strip()]
        at_line = {}
        for pos, ln in enumerate(lines):
            at_line.setdefault(ln.lower(), pos)
        for word in words_by_offset[start]:
            pos = at_line.get(word.lower())
            if pos is None or pos + 1 >= len(lines):
                continue  # headword not found as its own line: don't guess
            trans = clean_translation(lines[pos + 1])
            if not is_arabic(trans) or not 2 <= len(trans) <= 60:
                continue
            entries.setdefault(word.lower(), trans)  # first translation wins

    write_stardict(args.out, "eng-ara", "English-Arabic (FreeDict)",
                   "FreeDict eng-ara 0.6.3, GPL; freedict.org", sorted(entries.items()))


def cmd_wordnet(args):
    src = Path(args.json_dir)
    # Synset files carry the definitions; entries files map lemmas to synsets.
    defs = {}
    for path in src.glob("*.json"):
        if path.name.startswith("entries-"):
            continue
        for sid, s in json.load(path.open(encoding="utf-8")).items():
            if not isinstance(s, dict):
                continue
            d = (s.get("definition") or [""])[0].strip()
            if d:
                defs[sid] = d

    entries = {}
    for path in sorted(src.glob("entries-*.json")):
        for lemma, poses in json.load(path.open(encoding="utf-8")).items():
            if not lemma or not lemma[0].islower() or len(lemma) < 2:
                continue  # proper nouns and single letters never make a hint
            # The first sense WordNet lists is its most common one. Picking
            # the shortest definition instead grabbed the rarest sense for
            # polysemous words ("run" -> the baseball sense).
            definition = None
            for pos in poses.values():
                for sense in pos.get("sense", []):
                    d = defs.get(sense.get("synset"))
                    if d:
                        definition = d
                        break
                if definition:
                    break
            if definition and len(definition) <= 120:
                entries[lemma] = definition

    write_stardict(args.out, "wordnet-en", "English definitions (WordNet)",
                   "Open English WordNet 2025, CC BY 4.0; globalwordnet.github.io",
                   sorted(entries.items()))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("freedict", help="FreeDict eng-ara dictd release -> StarDict")
    f.add_argument("dict_dz")
    f.add_argument("index")
    f.add_argument("--out", required=True)
    w = sub.add_parser("wordnet", help="Open English WordNet json -> StarDict")
    w.add_argument("json_dir")
    w.add_argument("--out", required=True)
    args = ap.parse_args()
    (cmd_freedict if args.cmd == "freedict" else cmd_wordnet)(args)
